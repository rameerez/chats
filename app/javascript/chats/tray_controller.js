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
//   * on its own    (`standalone`: a corner of its own, no dock around it)
//                   it also hides on any page carrying [data-chats-dock-hide]
//                   and fits the visual viewport, which the dock otherwise does
//
// Registered automatically as "chats--tray" through the engine's importmap
// pin (see config/importmap.rb and Chats::Engine).

const SHEET = "(max-width: 699.98px), (max-height: 499.98px)" // keep in step with chats.css
const REFRESH_DELAY_MS = 300

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
  }

  // Every item's `toggle` (it doesn't bubble: each item names this action).
  toggled(event) {
    const item = event.target
    if (!this.itemTargets.includes(item)) return

    item.toggleAttribute("data-chats-minimized", !item.open)
    if (item.open) {
      this.itemTargets.forEach((other) => { if (other !== item) other.open = false })
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

  catchUp() {
    this.itemTargets.forEach((item) => {
      const url = item.dataset.chatsTrayBadgeUrl
      if (url) renderStreamFrom(url)
    })
  }

  // --- Pages ---------------------------------------------------------------

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
    this.fitViewport()
    this.syncSheet()
  }

  fitViewport = () => {
    if (this.corner) fitViewport(this.corner, this.compact)
  }

  // On a phone, an open item is modal: everything around it is held inert,
  // and the page doesn't scroll, until it closes.
  syncSheet() {
    const item = this.openItem
    const hidden = this.corner?.hidden || this.element.closest(".chats-dock")?.hidden
    if (this.compact && item && !hidden) {
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
    // A sheet always starts closed: on a phone, only a desk's choice is kept.
    this.write({ open: this.compact ? saved.open || null : this.openItem?.dataset.chatsTrayKey || null })
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

function cssEscape(value) {
  return window.CSS?.escape ? window.CSS.escape(value) : String(value).replace(/["\\]/g, "\\$&")
}
