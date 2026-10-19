import { Controller } from "@hotwired/stimulus"
import { recoverMissedBroadcasts, renderStreamFrom } from "chats/recovery"
import { around, fitViewport, holdInert, lockScroll, releaseInert } from "chats/sheet"

// chats--tray: the items a host puts in the corner (`chats_dock { … }`, or
// `chats_tray { … }` on its own), each a <details> rendered by
// `chats_tray_item`: closed, a tab on the bottom edge (a round button on a
// phone); open, a panel with the dock's skin (a full-screen sheet on a
// phone). The server renders the items and their content; this controller
// runs them:
//
//   * one open      opening an item closes the others, and (`chats--tray:open`,
//                   handled by chats--dock synchronously) the dock's panel;
//                   the dock's panel opening closes the open item
//   * the read gate every item carries data-chats-active and, while closed,
//                   data-chats-minimized: the attributes a dock window has,
//                   which chats' thread controller obeys, so a thread inside
//                   a closed item never reads. Opening it dispatches
//                   `chats:activated`, and a read that waited happens then.
//   * the sheet     on a phone an open item is modal: everything around it
//                   inert and the page still (chats/sheet, shared with the
//                   dock's own sheet, so one closing never frees the other's)
//   * keyboard      Escape closes the open item, focus back on its tab (the
//                   thread's own popups close themselves first)
//   * memory        which item was open, on a desk only (a sheet always
//                   starts closed), per owner in localStorage
//                   (`chats:tray:v1:<owner>`). Every access is guarded.
//   * badges        an item's badge (`chats_tray_badge`) arrives on its
//                   owner's stream; what the stream missed (chats/recovery)
//                   is asked again from the item's data-chats-tray-badge-url.
//                   When a badge's count moves, the frames of the item's
//                   content marked [data-chats-tray-refresh] reload: now if
//                   the item is open, when it opens if it is closed.
//   * never twice   a thread the page shows (or a dock window) is never
//                   also shown in an item: the item's
//                   turbo-frame[data-chats-tray-home] goes back home. The
//                   live streams address a thread's ids, which must exist once.
//   * room          an open item is as wide as the corner leaves it: the
//                   screen less the insets, the dock's panel and every other
//                   item (`--chats-tray-room`, measured); when that is less
//                   than `--chats-tray-min-width`, it opens as the sheet, as
//                   on a phone (`.chats-tray__item--sheet`)
//   * visits        the tray is carried from page to page (permanent), and
//                   reconciled with the items the new page rendered: their
//                   words, badges, badge URLs, streams and panels are the new
//                   page's; only an item's open state, and a frame open in it
//                   that the new page renders too (what is being read), stay
//   * on its own    (`standalone`: a corner of its own, no dock around it)
//                   it also hides on any page carrying [data-chats-dock-hide]
//                   and fits the visual viewport, which the dock otherwise does
//
// Registered automatically as "chats--tray" through the engine's importmap
// pin (see config/importmap.rb and Chats::Engine).

const SHEET = "(max-width: 699.98px), (max-height: 499.98px)" // keep in step with chats.css
const AS_SHEET = "chats-tray__item--sheet"
const REFRESH_DELAY_MS = 300
// What a visit refreshes on a retained item, and what it never touches.
const KEPT_ATTRIBUTES = new Set(["open", "data-chats-minimized", "data-chats-active", "class", "style"])

export default class extends Controller {
  static targets = ["item", "badge"]
  static values = { owner: String, standalone: Boolean }

  // Stimulus runs the target callbacks BEFORE connect(): set up here.
  initialize() {
    this.counts = new WeakMap()
    this.stale = new WeakSet()
  }

  connect() {
    this.corner = this.standaloneValue ? this.element.closest(".chats-dock") || this.element : null
    this.media = window.matchMedia(SHEET)
    this.media.addEventListener?.("change", this.layout)
    window.addEventListener("resize", this.resized)
    if (this.corner) {
      window.visualViewport?.addEventListener("resize", this.fitViewport)
      window.visualViewport?.addEventListener("scroll", this.fitViewport)
    }

    this.layout()
    this.restore()
    this.pageChanged()

    this.stopRecovery = recoverMissedBroadcasts(this.element, () => this.catchUp(),
                                                { sources: ".chats-tray__launcher turbo-cable-stream-source" })
  }

  disconnect() {
    this.media?.removeEventListener?.("change", this.layout)
    window.removeEventListener("resize", this.resized)
    window.visualViewport?.removeEventListener("resize", this.fitViewport)
    window.visualViewport?.removeEventListener("scroll", this.fitViewport)
    clearTimeout(this.refreshTimer)
    this.releaseSheet()
    this.stopRecovery?.()
  }

  // --- Items ---------------------------------------------------------------

  itemTargetConnected(item) {
    item.dataset.chatsActive = "true"
    item.toggleAttribute("data-chats-minimized", !item.open)
    if (this.compact) item.classList.add(AS_SHEET)
  }

  // Every item's `toggle` (it doesn't bubble: each item names this action).
  toggled(event) {
    const item = event.target
    if (!this.itemTargets.includes(item)) return

    item.toggleAttribute("data-chats-minimized", !item.open)
    if (item.open) {
      this.itemTargets.forEach((other) => { if (other !== item) other.open = false })
      this.fit(item)
      this.dispatch("open", { target: item, detail: { key: item.dataset.chatsTrayKey } })
      item.dispatchEvent(new CustomEvent("chats:activated"))
      if (this.stale.has(item)) this.refresh(item)
    } else {
      this.dispatch("close", { target: item, detail: { key: item.dataset.chatsTrayKey } })
    }
    this.syncSheet()
    this.save()
  }

  get openItem() {
    return this.itemTargets.find((item) => item.open)
  }

  close(item) {
    if (!item?.open) return

    item.open = false
    item.querySelector("summary")?.focus()
  }

  // --- Keyboard ------------------------------------------------------------

  keydown(event) {
    if (event.key !== "Escape" || event.defaultPrevented) return
    // The thread's long-press popup and photo preview close themselves.
    if (event.target.closest?.(".chats-popup, .chats-attachment-preview")) return
    if (this.element.querySelector(".chats-popup:not([hidden]), .chats-attachment-preview:not([hidden])")) return

    const item = this.openItem
    if (!item) return

    event.preventDefault()
    this.close(item)
  }

  // --- Badges and their content ---------------------------------------------

  // A badge arrived (the server's, or one its owner's stream replaced): when
  // the count moved, what the item shows may be stale.
  badgeTargetConnected(badge) {
    const item = badge.closest(".chats-tray__item")
    if (!item) return

    const count = Number(badge.dataset.count || 0)
    const before = this.counts.get(item)
    this.counts.set(item, count)
    if (before === undefined || before === count) return

    if (count > before) this.flash(badge, "chats-badge--bumped", 200)
    this.refresh(item)
  }

  // Reload the frames that asked to follow the badge: debounced while open,
  // marked stale while closed (they reload on open).
  refresh(item) {
    if (!item.open) {
      this.stale.add(item)
      return
    }
    this.stale.delete(item)
    clearTimeout(this.refreshTimer)
    this.refreshTimer = setTimeout(() => {
      this.refreshableFrames(item).forEach((frame) => frame.reload?.())
    }, REFRESH_DELAY_MS)
  }

  refreshableFrames(item) {
    const frames = new Set()
    item.querySelectorAll("[data-chats-tray-refresh]").forEach((marker) => {
      const frame = marker.closest("turbo-frame")
      if (frame && item.contains(frame)) frames.add(frame)
    })
    return Array.from(frames)
  }

  // Each item's badge asked again. Only from this site: what comes back is a
  // Turbo Stream applied to the page, so a badge URL on another origin (one
  // that answers CORS) is refused, never fetched.
  catchUp() {
    this.itemTargets.forEach((item) => {
      const url = sameOrigin(item.dataset.chatsTrayBadgeUrl)
      if (url) renderStreamFrom(url)
    })
  }

  // --- Pages ---------------------------------------------------------------

  // A visit is about to render, and Turbo will keep this (permanent) tray
  // rather than the one the new page rendered: make its items the new
  // page's, by key. One the page no longer renders goes; a new one comes in;
  // one still there takes everything the new page says about it (see
  // refreshItem), in the new page's order.
  reconcile(event) {
    const find = (id) => event.detail?.newBody?.querySelector?.(`[id="${cssEscape(id)}"]`)
    // The permanent element the tray rides in (the dock, or its own corner):
    // only when the new page renders it too does Turbo carry this tray there.
    const holder = this.element.closest("[data-turbo-permanent]")
    const newHolder = holder ? find(holder.id) : find(this.element.id)
    if (!newHolder) return

    const incoming = holder ? newHolder.querySelector(`[id="${cssEscape(this.element.id)}"]`) : newHolder
    const current = new Map(this.itemTargets.map((item) => [item.dataset.chatsTrayKey, item]))
    const wanted = incoming ? Array.from(incoming.querySelectorAll(":scope > .chats-tray__item")) : []
    const keys = new Set(wanted.map((item) => item.dataset.chatsTrayKey))
    const sameOrder = wanted.map((item) => item.dataset.chatsTrayKey).join("\n") === Array.from(current.keys()).join("\n")

    current.forEach((item, key) => { if (!keys.has(key)) item.remove() })
    wanted.forEach((fresh) => {
      const kept = current.get(fresh.dataset.chatsTrayKey)
      if (kept) this.refreshItem(kept, fresh)
      // The new page's order. When it is the same, nothing moves: a move
      // reconnects what is in the item (its streams, an open thread).
      if (!kept || !sameOrder) this.element.append(kept || document.importNode(fresh, true))
    })
  }

  // A retained item takes the new page's version of itself: its attributes
  // (the badge URL among them), its tab (words, icon, badge, the badge's
  // stream) and its panel. It keeps only what the viewer did: whether it is
  // open, and, while it is open, a frame of its panel the new page renders
  // too (by id), live, where it is: what they are reading or writing.
  refreshItem(kept, fresh) {
    Array.from(kept.attributes).forEach(({ name }) => {
      if (!KEPT_ATTRIBUTES.has(name) && !fresh.hasAttribute(name)) kept.removeAttribute(name)
    })
    Array.from(fresh.attributes).forEach(({ name, value }) => {
      if (!KEPT_ATTRIBUTES.has(name)) kept.setAttribute(name, value)
    })

    const summary = kept.querySelector(":scope > summary")
    const freshSummary = fresh.querySelector(":scope > summary")
    if (freshSummary && summary) {
      summary.replaceWith(document.importNode(freshSummary, true))
    } else if (freshSummary) {
      kept.prepend(document.importNode(freshSummary, true))
    }

    const body = kept.querySelector(":scope > .chats-tray__body")
    const freshBody = fresh.querySelector(":scope > .chats-tray__body")
    if (!body || !freshBody) return
    Array.from(freshBody.attributes).forEach(({ name, value }) => body.setAttribute(name, value))

    const live = new Map()
    if (kept.open) body.querySelectorAll(":scope > turbo-frame[id]").forEach((frame) => live.set(frame.id, frame))
    const staying = new Set(Array.from(freshBody.children).filter((node) => live.has(node.id)).map((node) => live.get(node.id)))
    Array.from(body.childNodes).forEach((node) => { if (!staying.has(node)) node.remove() })
    let anchor = body.firstChild
    Array.from(freshBody.childNodes).forEach((node) => {
      const frame = node.id && live.get(node.id)
      if (frame && staying.has(frame)) {
        anchor = frame.nextSibling // it stays where it is
      } else {
        body.insertBefore(document.importNode(node, true), anchor)
      }
    })
  }

  // After every visit: on its own, hidden on the pages that hide the dock;
  // anywhere, no item keeps a thread the page now shows.
  pageChanged() {
    if (this.corner) {
      const hide = Array.from(document.querySelectorAll("[data-chats-dock-hide]"))
        .some((node) => !this.corner.contains(node))
      this.corner.hidden = hide
      if (hide) this.itemTargets.forEach((item) => { item.open = false })
    }
    this.yieldDuplicates()
    this.syncSheet()
  }

  // A frame loaded somewhere (a dock window, the page's pane, an item's own):
  // the same rule.
  frameLoaded() {
    this.yieldDuplicates()
  }

  // A thread is identified by its history's id (dom_id(conversation,
  // :history)): one inside an item that also exists outside it sends the
  // item's home frames back home.
  yieldDuplicates() {
    this.itemTargets.forEach((item) => {
      const twice = Array.from(item.querySelectorAll(".chats-thread__scroll[id]")).some((history) =>
        Array.from(document.querySelectorAll(`[id="${cssEscape(history.id)}"]`)).some((other) => !item.contains(other)))
      if (!twice) return

      item.querySelectorAll("turbo-frame[data-chats-tray-home]").forEach((frame) => {
        frame.replaceChildren()
        frame.src = frame.dataset.chatsTrayHome
      })
    })
  }

  // --- The sheet -------------------------------------------------------------

  layout = () => {
    const compact = this.media.matches
    if (this.compact === false && compact) this.itemTargets.forEach((item) => { item.open = false })

    this.compact = compact
    if (this.corner) this.corner.dataset.mode = compact ? "sheet" : "dock"
    this.itemTargets.forEach((item) => (item.open ? this.fit(item) : item.classList.toggle(AS_SHEET, compact)))
    this.fitViewport()
    this.syncSheet()
  }

  // The viewport changed size: the open item fits again (or becomes the sheet).
  resized = () => {
    const item = this.openItem
    if (!item) return

    this.fit(item)
    this.syncSheet()
  }

  // How wide +item+ may open: the screen less the insets, the dock's panel
  // and every other item with its gap. Too little (under
  // --chats-tray-min-width), or a phone: the sheet.
  fit(item) {
    const room = this.roomFor(item)
    item.style.setProperty("--chats-tray-room", `${Math.max(0, Math.floor(room))}px`)
    item.classList.toggle(AS_SHEET, Boolean(this.compact) || room < this.pixels("--chats-tray-min-width", 280))
  }

  roomFor(item) {
    const gap = this.pixels("--chats-dock-gap", 8)
    const panel = this.element.closest(".chats-dock")?.querySelector(":scope > .chats-dock__panel")
    let taken = 2 * this.pixels("--chats-dock-inset", 16) + (panel ? panel.offsetWidth + gap : 0)
    this.itemTargets.forEach((other) => { if (other !== item) taken += other.offsetWidth + gap })
    return window.innerWidth - taken
  }

  pixels(property, fallback) {
    const value = getComputedStyle(this.element).getPropertyValue(property).trim()
    return value.endsWith("px") ? parseFloat(value) : fallback
  }

  fitViewport = () => {
    if (this.corner) fitViewport(this.corner, this.compact)
  }

  // Open as the sheet (a phone, or a corner too narrow for it), an item is
  // modal: everything around it is held inert, and the page doesn't scroll,
  // until it closes.
  syncSheet() {
    const item = this.openItem
    const hidden = this.corner?.hidden || this.element.closest(".chats-dock")?.hidden
    if (item?.classList.contains(AS_SHEET) && !hidden) {
      holdInert(this, around(item))
      lockScroll(this, true)
    } else {
      this.releaseSheet()
    }
  }

  releaseSheet() {
    releaseInert(this)
    lockScroll(this, false)
  }

  // --- Memory ----------------------------------------------------------------

  get storageKey() {
    return `chats:tray:v1:${this.ownerValue}`
  }

  save() {
    const saved = this.read() || {}
    const open = this.openItem
    // A sheet always starts closed: on a phone, only a desk's choice is kept,
    // and an item that opened as the sheet on a narrow desk isn't remembered.
    if (this.compact) return this.write({ open: saved.open || null })
    this.write({ open: open && !open.classList.contains(AS_SHEET) ? open.dataset.chatsTrayKey : null })
  }

  // The item that was open, on a desk. A Turbo visit carries the live
  // element along, so this only ever reopens what is already open.
  restore() {
    if (this.compact || this.openItem) return

    const key = this.read()?.open
    if (typeof key !== "string") return
    const item = this.itemTargets.find((candidate) => candidate.dataset.chatsTrayKey === key)
    if (item) item.open = true
  }

  read() {
    try {
      const saved = JSON.parse(window.localStorage.getItem(this.storageKey) || "null")
      return saved && typeof saved === "object" ? saved : null
    } catch {
      return null
    }
  }

  write(value) {
    try {
      window.localStorage.setItem(this.storageKey, JSON.stringify(value))
    } catch {
      // nothing to remember with
    }
  }

  flash(element, className, duration) {
    element.classList.add(className)
    setTimeout(() => element.classList.remove(className), duration)
  }
}

// +url+ resolved against the page, when it is on the page's own origin; null
// (and said, in the console) when it is not.
function sameOrigin(url) {
  if (!url) return null
  try {
    const resolved = new URL(url, window.location.href)
    if (resolved.origin === window.location.origin) return resolved.toString()
  } catch {
    // not a URL at all
  }
  console.error(`chats--tray: refusing a badge URL on another origin: ${url}`)
  return null
}

function cssEscape(value) {
  return window.CSS?.escape ? window.CSS.escape(value) : String(value).replace(/["\\]/g, "\\$&")
}
