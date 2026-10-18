import { Controller } from "@hotwired/stimulus"

// chats--dock: the messaging dock (`chats_dock`) — LinkedIn / Steam style
// floating conversation windows in the bottom-right corner.
//
// The server renders everything: the panel (a <details>, so it opens with
// no JavaScript), its recent list (a lazy turbo frame), and every window's
// thread (a turbo frame loading `?window=1`). This controller only arranges
// them:
//
//   * windows      open from a row, from `chat_button_to …, dock: true` (a
//                  Turbo Stream appends the frame) or from a live message;
//                  minimize, close; at most `windows` of them, and never
//                  more than fit beside the panel — opening one more closes
//                  the oldest. Never one for a conversation the page itself
//                  renders (the streams address the thread's DOM ids, which
//                  must exist once).
//   * persistence  which windows are open, and which are minimized, per
//                  messager in localStorage — a full reload brings them back
//   * live         the viewer's `[messager, :chats_dock]` stream replaces the
//                  badge; when the new badge connects, the recent list
//                  reloads and, when the server says so (`data-pop-up`), the
//                  conversation's window opens. No polling.
//   * phones       below --chats-dock-breakpoint (640px) the dock is a round
//                  button, the panel a full-screen sheet, and ONE window at a
//                  time fills the screen; ‹ goes back to the list
//   * keyboard     Escape closes the window you are in (or the panel); a
//                  window opened by a click puts the focus in its composer
//
// The element is data-turbo-permanent: Turbo Drive carries it, windows and
// all, from page to page. A visit may detach and reattach it, so connect()
// must tell a fresh dock (restore) from a moved one (keep what is there).
//
// Registered automatically as "chats--dock" through the engine's importmap
// pin (see config/importmap.rb and Chats::Engine).
const MINIMIZED = "chats-window--minimized"
const UNREAD = "chats-window--unread"
const COMPACT = "chats-dock--compact"

export default class extends Controller {
  static targets = ["windows", "window", "panel", "list", "badge"]
  static values = {
    windows: { type: Number, default: 3 },
    storageKey: String,
    windowUrl: String,
    // dom_id's record key for a conversation, from the server: inside the
    // isolated engine it is "conversation", not "chats_conversation", and
    // nothing here should have to know that.
    recordKey: { type: String, default: "conversation" },
    loading: String
  }

  connect() {
    this.media = window.matchMedia(`not all and (min-width: ${this.breakpoint})`)
    this.media.addEventListener?.("change", this.layout)
    window.visualViewport?.addEventListener("resize", this.fitViewport)
    window.visualViewport?.addEventListener("scroll", this.fitViewport)
    this.layout()

    if (this.windowTargets.length === 0) this.restore()
  }

  disconnect() {
    this.media?.removeEventListener?.("change", this.layout)
    window.visualViewport?.removeEventListener("resize", this.fitViewport)
    window.visualViewport?.removeEventListener("scroll", this.fitViewport)
  }

  // --- Opening ---------------------------------------------------------------

  // A recent-list row. It is a real link to the thread: a click that means
  // "somewhere else" (new tab, new window) is left alone.
  open(event) {
    if (event.defaultPrevented || event.button > 0) return
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return

    event.preventDefault()
    this.openWindow(String(event.params.id), { focus: true })
  }

  openWindow(id, { minimized = false, focus = false } = {}) {
    if (this.renderedOnPage(id)) {
      // Already on the page: go to it rather than open a second copy.
      this.panelTarget.open = false
      document.getElementById(this.domId("composer", id))?.querySelector("textarea")?.focus()
      return
    }

    const open = this.windowFor(id)
    if (open) {
      this.setMinimized(open, false)
      if (focus) this.focusComposer(open)
      return
    }

    this.windowsTarget.append(this.buildWindow(id, { minimized, focus }))
  }

  // Every window arrives here, whoever made it: this controller, or the
  // Turbo Stream `chat_button_to …, dock: true` answers with (which renders
  // the same element from chats/dock/_window — keep the two in step).
  windowTargetConnected(frame) {
    const id = frame.dataset.conversationId
    if (this.renderedOnPage(id)) return frame.remove()

    this.windowTargets.forEach((other) => {
      if (other !== frame && other.dataset.conversationId === id) other.remove()
    })

    if (frame.hasAttribute("data-focus")) {
      frame.removeAttribute("data-focus")
      this.setMinimized(frame, false, { persist: false })
      this.focusComposer(frame)
    }

    this.enforceCap(frame)
    this.save()
  }

  buildWindow(id, { minimized, focus }) {
    const frame = document.createElement("turbo-frame")
    frame.id = this.domId("window", id)
    frame.className = minimized ? `chats-window ${MINIMIZED}` : "chats-window"
    frame.setAttribute("target", "_top")
    frame.setAttribute("data-chats--dock-target", "window")
    frame.dataset.conversationId = id
    if (focus) frame.dataset.focus = ""

    const loader = document.createElement("div")
    loader.className = "chats-loader"
    loader.textContent = this.loadingValue
    frame.append(loader)

    frame.src = this.windowUrlValue.replace("__id__", encodeURIComponent(id))
    return frame
  }

  // Newest windows are last (nearest the panel), so the oldest go first.
  enforceCap(keep) {
    let excess = this.windowTargets.length - this.cap
    for (const frame of this.windowTargets) {
      if (excess <= 0) break
      if (frame === keep) continue
      frame.remove()
      excess--
    }
  }

  get cap() {
    if (this.compact) return 1

    // Never more windows than fit beside the panel: a fourth one on a
    // laptop screen would hang off the left edge.
    const room = window.innerWidth - this.panelTarget.offsetWidth - 32
    const width = this.windowTargets[0]?.offsetWidth || 320
    return Math.max(1, Math.min(this.windowsValue, Math.floor(room / (width + 8))))
  }

  // --- Live ------------------------------------------------------------------

  // The badge is replaced on the viewer's dock stream whenever their unread
  // state changes (Chats::Broadcasts.update_badge_of). The server-rendered
  // badge carries no `data-changed`; a broadcast one does, and we consume it
  // so the same node reconnecting (a Turbo Drive visit) never acts twice.
  badgeTargetConnected(badge) {
    if (!badge.hasAttribute("data-changed")) return

    badge.removeAttribute("data-changed")
    const popUp = badge.hasAttribute("data-pop-up")
    badge.removeAttribute("data-pop-up")

    this.refreshList()
    const id = badge.dataset.latestConversationId
    if (id && popUp) this.popUp(id)
  }

  // A message arrived that the viewer should see.
  popUp(id) {
    const open = this.windowFor(id)
    if (open) {
      if (this.minimized(open)) open.classList.add(UNREAD)
      return
    }
    // A phone shows one window and it fills the screen: a message never
    // takes the screen away from what its owner is doing. The badge on the
    // button says it.
    if (this.compact || this.renderedOnPage(id)) return

    if (this.windowTargets.length < this.cap) return this.openWindow(id)

    // Full: it may take the place of a minimized window, minimized — never
    // the place of a conversation somebody has open.
    const idle = this.windowTargets.find((frame) => this.minimized(frame))
    if (!idle) return
    idle.remove()
    this.openWindow(id, { minimized: true })
  }

  refreshList() {
    if (!this.hasListTarget || !this.listTarget.hasAttribute("complete")) return // never loaded: it loads fresh on open

    if (this.panelTarget.open) {
      this.listTarget.reload()
    } else {
      this.listStale = true
    }
  }

  panelToggled() {
    if (!this.panelTarget.open || !this.listStale) return

    this.listStale = false
    this.listTarget.reload()
  }

  // The sender gets no badge broadcast for their own message, but their
  // recent list still reorders: a send from one of our windows refreshes it.
  sent(event) {
    if (!event.detail?.success) return
    if (this.windowTargets.some((frame) => frame.contains(event.target))) this.refreshList()
  }

  // --- Window controls -------------------------------------------------------

  // A click on a window's header (not on its links or buttons) folds it.
  toggleWindow(event) {
    if (this.compact || event.target.closest("a, button")) return

    const frame = this.frameOf(event.target)
    if (frame) this.setMinimized(frame, !this.minimized(frame))
  }

  minimize(event) {
    const frame = this.frameOf(event.target)
    if (frame) this.setMinimized(frame, !this.minimized(frame))
  }

  close(event) {
    this.closeWindow(this.frameOf(event.target))
  }

  // Phones: one window at a time, over the list it came from.
  back(event) {
    this.closeWindow(this.frameOf(event.target))
    this.panelTarget.open = true
  }

  closeWindow(frame) {
    if (!frame) return

    const hadFocus = frame.contains(document.activeElement)
    frame.remove()
    this.save()
    if (hadFocus) this.panelTarget.querySelector("summary")?.focus()
  }

  setMinimized(frame, minimized, { persist = true } = {}) {
    frame.classList.toggle(MINIMIZED, minimized)
    if (!minimized) frame.classList.remove(UNREAD)
    this.syncControls(frame)
    if (persist) this.save()
  }

  // The minimize button is a disclosure: aria-expanded says which way it
  // goes. The server renders it expanded; a window restored minimized
  // corrects it once its content arrives.
  syncControls(frame) {
    frame.querySelector("[data-chats-dock-minimize]")
      ?.setAttribute("aria-expanded", String(!this.minimized(frame)))
  }

  frameLoaded(event) {
    if (this.windowTargets.includes(event.target)) this.syncControls(event.target)
  }

  focusComposer(frame) {
    const focus = () => frame.querySelector(".chats-composer__input")?.focus({ preventScroll: true })

    if (frame.querySelector(".chats-composer__input")) {
      focus()
    } else {
      frame.addEventListener("turbo:frame-load", focus, { once: true })
    }
  }

  // A window whose conversation is gone for this viewer (they left, a block
  // hides it) answers 404 without its frame: close it quietly instead of
  // letting Turbo print "Content missing" into the dock.
  frameMissing(event) {
    if (!this.windowTargets.includes(event.target)) return

    event.preventDefault()
    event.target.remove()
    this.save()
  }

  // A visit to a page that renders one of our open conversations (a dock
  // rendered with `everywhere: true`): the page wins, the window goes.
  pageChanged() {
    this.windowTargets.forEach((frame) => {
      if (this.renderedOnPage(frame.dataset.conversationId)) frame.remove()
    })
    this.save()
  }

  // Escape closes the window the focus is in, or else the open panel. Only
  // from inside the dock, so a host's own dialog keeps its Escape, and never
  // while the thread's long-press popup or photo preview is up (theirs).
  escape(event) {
    if (event.target.closest(".chats-popup, .chats-attachment-preview")) return
    if (this.element.querySelector(".chats-popup:not([hidden]), .chats-attachment-preview:not([hidden])")) return

    const frame = this.windowTargets.find((candidate) => candidate.contains(event.target))
    if (frame) return this.closeWindow(frame)

    if (this.panelTarget.open) {
      this.panelTarget.open = false
      this.panelTarget.querySelector("summary")?.focus()
    }
  }

  // --- Persistence -------------------------------------------------------------
  //
  // localStorage may be missing, full, or refuse access (private modes,
  // blocked site data): the dock then simply forgets, so every access is
  // guarded.

  save() {
    const state = this.windowTargets.map((frame) => ({
      id: frame.dataset.conversationId,
      minimized: this.minimized(frame)
    }))

    try {
      window.localStorage.setItem(this.storageKeyValue, JSON.stringify(state))
    } catch {
      // nothing to remember with
    }
  }

  restore() {
    let state
    try {
      state = JSON.parse(window.localStorage.getItem(this.storageKeyValue) || "[]")
    } catch {
      return
    }
    if (!Array.isArray(state)) return

    state.forEach((saved) => {
      if (saved?.id) this.openWindow(String(saved.id), { minimized: Boolean(saved.minimized) })
    })
  }

  // --- Layout --------------------------------------------------------------------

  // Media queries can't read custom properties, so the breakpoint is read
  // here and the phone layout keyed on a class (chats.css, .chats-dock--compact).
  get breakpoint() {
    return getComputedStyle(this.element).getPropertyValue("--chats-dock-breakpoint").trim() || "640px"
  }

  layout = () => {
    this.compact = this.media.matches
    this.element.classList.toggle(COMPACT, this.compact)
    this.fitViewport()

    if (this.windowTargets.length > this.cap) {
      this.enforceCap(this.windowTargets[this.windowTargets.length - 1])
      this.save()
    }
  }

  // Full-screen on a phone means the VISIBLE viewport: with the keyboard up
  // it is shorter than 100dvh, and the composer must stay above the keys.
  fitViewport = () => {
    const viewport = window.visualViewport
    if (!this.compact || !viewport) return

    this.element.style.setProperty("--chats-dock-viewport-height", `${viewport.height}px`)
    this.element.style.setProperty("--chats-dock-viewport-top", `${viewport.offsetTop}px`)
  }

  // --- Lookups ---------------------------------------------------------------------

  windowFor(id) {
    return this.windowTargets.find((frame) => frame.dataset.conversationId === id)
  }

  frameOf(element) {
    return element?.closest(".chats-window")
  }

  minimized(frame) {
    return frame.classList.contains(MINIMIZED)
  }

  // Whether the page itself (not one of our windows) renders this thread.
  renderedOnPage(id) {
    return Array.from(document.querySelectorAll(`[id="${CSS.escape(this.domId("messages", id))}"]`))
      .some((element) => !this.element.contains(element))
  }

  // dom_id(conversation, prefix), as the server writes it.
  domId(prefix, id) {
    return `${prefix}_${this.recordKeyValue}_${id}`
  }
}
