import { Controller } from "@hotwired/stimulus"

// chats--dock: the messaging dock (`chats_dock`) — LinkedIn / Steam style
// floating conversation windows in the bottom-right corner.
//
// The server renders everything: the panel (a <details>, so it opens with
// no JavaScript), its recent list (a lazy turbo frame), every window's
// thread (a turbo frame loading `?window=1`), and the phone layout (one
// media query in chats.css). This controller arranges and remembers:
//
//   * windows      open from a row or any `chats_dock_opener` link, from
//                  `chat_button_to …, dock: true` (a Turbo Stream appends
//                  the frame; an open one is focused, never reloaded), or
//                  from a live message. Never more than fit beside the
//                  panel (min(windows, floor((vw − 312) / 344)): 2 at
//                  1280px, 1 at 768px); room is made by closing the least
//                  recently used window that doesn't have the focus, and
//                  its unsent text is kept. Never one for a conversation
//                  the page itself renders: the streams address the
//                  thread's DOM ids, which must exist once.
//   * reading      a window marks messages read only when it is expanded
//                  AND the viewer is engaged with it (`data-chats-active`,
//                  which the thread controller obeys). One the viewer
//                  opened is engaged from the start; one that popped open,
//                  or came back after a reload, once they focus, press or
//                  scroll in it.
//   * live         the viewer's `[messager, :chats_dock]` stream replaces
//                  the signal template; when it connects, the recent list
//                  reloads and, for a message the viewer should hear about,
//                  its window pops open (in dock mode only, never stealing
//                  focus, never for one closed in the last five minutes,
//                  never over a window in use) and is announced politely.
//   * memory       per viewer in localStorage (`chats:dock:v1:<key>`):
//                  which windows, minimized or not, recently closed ones,
//                  and the panel; drafts under `chats:draft:<key>:<id>`.
//                  Every access is guarded: no storage, no memory, no harm.
//   * hiding       on any page with [data-chats-dock-hide] (the engine's
//                  inbox and thread), since a permanent element is never
//                  re-rendered by the server
//   * keyboard     Escape unwinds innermost first: the thread's popup or
//                  photo, an edit, the window menu, then the window
//                  (minimized), the panel (closed); on a phone, the window
//                  back to the list, then the list closed
//
// The element is data-turbo-permanent: Turbo Drive carries it, windows and
// all, from page to page, and may detach and reattach it, so connect()
// keeps whatever windows are already there.
//
// Registered automatically as "chats--dock" through the engine's importmap
// pin (see config/importmap.rb and Chats::Engine).

const SHEET = "(max-width: 699.98px), (max-height: 499.98px)" // keep in step with chats.css
const MINIMIZED = "chats-window--minimized"
const UNREAD = "chats-window--unread"
const FRONT = "chats-window--front"
const ENTERING = "chats-window--entering"
const POPPED = "chats-window--popped"
const NO_REPOP_MS = 5 * 60_000
const ANNOUNCE_EVERY_MS = 30_000
const DRAFT_TTL_MS = 7 * 24 * 60 * 60_000
const DRAFT_DELAY_MS = 500
const LIST_DELAY_MS = 300

export default class extends Controller {
  static targets = ["windows", "window", "panel", "list", "badge", "signal", "announcer", "loadingShell", "failedShell"]
  static values = {
    windows: { type: Number, default: 3 },
    messager: String,
    everywhere: Boolean,
    windowUrl: String,
    // dom_id's record key for a conversation, from the server: inside the
    // isolated engine it is "conversation", not "chats_conversation".
    recordKey: { type: String, default: "conversation" },
    announcement: String,
    windowUnread: String
  }

  // Stimulus runs the target callbacks (windowTargetConnected…) BEFORE
  // connect(), so everything they touch is set up here.
  initialize() {
    this.openers = new WeakMap()
    this.announced = {}
    this.inerted = []
    this.closed = this.read(this.storageKey)?.closed || {}
  }

  connect() {
    this.media = window.matchMedia(SHEET)
    this.media.addEventListener?.("change", this.layout)
    window.addEventListener("resize", this.resized)
    window.visualViewport?.addEventListener("resize", this.fitViewport)
    window.visualViewport?.addEventListener("scroll", this.fitViewport)

    // A window always names its viewer. One that doesn't match never stays:
    // nothing of one account may surface in another's page.
    this.windowTargets.forEach((frame) => {
      if (frame.dataset.chatsMessager !== this.messagerValue) frame.remove()
    })

    this.layout()
    this.restore()
    this.pageChanged()
  }

  disconnect() {
    this.media?.removeEventListener?.("change", this.layout)
    window.removeEventListener("resize", this.resized)
    window.visualViewport?.removeEventListener("resize", this.fitViewport)
    window.visualViewport?.removeEventListener("scroll", this.fitViewport)
    this.releaseSheet()
  }

  // --- Opening ---------------------------------------------------------------

  // Any [data-chats-dock-conversation-id] link (the rows, a host's own) and
  // any [data-chats-dock-toggle] (a host's Messages link), on the whole
  // page. They are real links: a click that means "somewhere else" (new
  // tab, new window) is left alone, and so is everything while the dock is
  // hidden.
  delegate(event) {
    if (event.defaultPrevented || event.button > 0 || this.element.hidden) return
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return

    const opener = event.target.closest("[data-chats-dock-conversation-id]")
    if (opener) {
      event.preventDefault()
      this.openWindow(String(opener.dataset.chatsDockConversationId), { focus: true, opener })
      return
    }

    const toggle = event.target.closest("[data-chats-dock-toggle]")
    if (toggle && !this.element.contains(toggle)) {
      event.preventDefault()
      this.panelTarget.open = !this.panelTarget.open
      if (this.panelTarget.open) this.summary.focus()
    }
  }

  // Opened by the viewer unless `active: false` (a pop-up, a restore).
  openWindow(id, { minimized = false, focus = false, active = true, opener = null } = {}) {
    if (this.renderedOnPage(id)) {
      // Already on the page: go to it rather than open a second copy.
      this.panelTarget.open = false
      document.getElementById(this.domId("composer", id))?.querySelector("textarea")?.focus()
      return null
    }

    const open = this.windowFor(id)
    if (open) {
      if (opener) this.openers.set(open, opener)
      this.show(open, { focus })
      return open
    }

    if (!this.makeRoom(null, { force: active })) return null

    const frame = this.buildWindow(id, { minimized, active, focus })
    if (opener) this.openers.set(frame, opener)
    this.windowsTarget.append(frame)
    return frame
  }

  // Every window arrives here, whoever made it: this controller, or the
  // Turbo Stream `chat_button_to …, dock: true` answers with (which renders
  // the same element from chats/dock/_window — keep the two in step). Also
  // called again for each window when a Turbo visit reattaches the dock.
  windowTargetConnected(frame) {
    const id = frame.dataset.conversationId
    if (this.renderedOnPage(id)) return frame.remove()

    frame.dataset.chatsMessager ||= this.messagerValue
    frame.dataset.usedAt ||= String(Date.now())
    this.windowTargets.forEach((other) => {
      if (other !== frame && other.dataset.conversationId === id) this.removeWindow(other)
    })
    this.makeRoom(frame, { force: true })

    if (!frame.hasAttribute("data-entered")) {
      frame.setAttribute("data-entered", "")
      this.flash(frame, ENTERING, 260)
    }
    if (frame.hasAttribute("data-focus")) {
      frame.removeAttribute("data-focus")
      this.show(frame, { focus: true })
    }

    this.syncControls(frame)
    this.markOpenRows()
    this.syncSheet()
    this.save()
  }

  // A repeated `dock: true` for a conversation already in a window: focus
  // that window. Turbo's append would replace it, reload the thread and
  // drop whatever is typed in it.
  beforeStreamRender(event) {
    const stream = event.target
    if (stream.getAttribute?.("action") !== "append" || stream.getAttribute("target") !== "chats_dock_windows") return

    const incoming = stream.templateContent?.querySelector("[data-conversation-id]")
    const open = incoming && this.windowFor(incoming.dataset.conversationId)
    if (!open) return

    event.preventDefault()
    this.show(open, { focus: true })
  }

  // Bring a window forward: expanded, engaged, in front on a phone.
  show(frame, { focus = false } = {}) {
    frame.dataset.usedAt = String(Date.now())
    this.setMinimized(frame, false)
    this.activate(frame)

    if (this.compact) {
      this.windowTargets.forEach((other) => other.classList.toggle(FRONT, other === frame))
      this.syncSheet()
    }
    if (focus) this.focusInside(frame)
  }

  buildWindow(id, { minimized, active, focus }) {
    const frame = document.createElement("turbo-frame")
    frame.id = this.domId("window", id)
    frame.className = minimized ? `chats-window ${MINIMIZED}` : "chats-window"
    frame.setAttribute("target", "_top")
    frame.setAttribute("data-chats--dock-target", "window")
    frame.dataset.conversationId = id
    frame.dataset.chatsMessager = this.messagerValue
    frame.dataset.chatsActive = String(active)
    if (focus) frame.dataset.focus = ""
    frame.append(this.shell("loading", this.rowName(id)))
    frame.src = this.windowUrlValue.replace("__id__", encodeURIComponent(id))
    return frame
  }

  // Make room for one more window (or, with +keeping+, for that one): close
  // the least recently used window that doesn't have the focus. Without
  // `force`, gives up rather than close one that does.
  makeRoom(keeping, { force = false } = {}) {
    const limit = keeping ? this.fit : this.fit - 1
    while (this.windowTargets.length > limit) {
      const victim = this.leastRecentlyUsed(keeping) || (force && this.oldest(keeping))
      if (!victim) return false
      this.removeWindow(victim)
    }
    return true
  }

  // How many windows fit beside the panel right now. On a phone they are
  // shown one at a time, so only the cap applies.
  get fit() {
    if (this.compact) return this.windowsValue

    const inset = this.pixels("--chats-dock-inset", 16)
    const gap = this.pixels("--chats-dock-gap", 8)
    const panel = this.panelTarget.offsetWidth || this.pixels("--chats-dock-panel-width", 288)
    const width = this.pixels("--chats-dock-window-width", 336)
    const room = Math.floor((window.innerWidth - inset - panel - gap) / (width + gap))
    return Math.max(1, Math.min(this.windowsValue, room))
  }

  // --- Live ------------------------------------------------------------------

  // The stream replaces the signal whenever something changed for this
  // viewer (Chats::Broadcasts.update_dock_of). The server-rendered one
  // carries no data-changed; a broadcast one does, consumed here so the
  // same node reconnecting (a Turbo Drive visit) never acts twice.
  signalTargetConnected(signal) {
    if (!signal.hasAttribute("data-changed")) return
    signal.removeAttribute("data-changed")
    this.refreshList()

    const id = signal.dataset.conversationId
    if (!id || !signal.hasAttribute("data-notify")) return
    signal.removeAttribute("data-notify")
    if (this.element.hidden) return

    this.popUp(id, Number(signal.dataset.unreadCount || 0))
    this.announce(id, signal.dataset.senderName)
  }

  // A message arrived that the viewer would be notified about (the server
  // has already ruled out their own and muted conversations).
  popUp(id, unread) {
    const open = this.windowFor(id)
    if (open) {
      if (this.minimized(open) || !this.engaged(open)) this.markUnread(open, unread)
      return
    }
    // A phone shows one window and it fills the screen: a message never
    // takes the screen away from what its owner is doing. The badge says it.
    if (this.compact || this.renderedOnPage(id) || this.recentlyClosed(id)) return

    const frame = this.openWindow(id, { active: false })
    if (!frame) return
    this.markUnread(frame, unread)
    this.flash(frame, POPPED, 1300)
  }

  markUnread(frame, count) {
    frame.classList.add(UNREAD)
    frame.dataset.unread = String(count || "")
    this.syncControls(frame)
  }

  // "New message from …" in the polite live region: at most once per
  // conversation every 30 seconds, never for the window you're typing in.
  announce(id, name) {
    if (!name || !this.hasAnnouncerTarget) return
    if (this.windowFor(id)?.contains(document.activeElement)) return

    const now = Date.now()
    if (now - (this.announced[id] || 0) < ANNOUNCE_EVERY_MS) return
    this.announced[id] = now

    this.announcerTarget.textContent = ""
    requestAnimationFrame(() => {
      this.announcerTarget.textContent = this.announcementValue.replace("%{name}", name)
    })
  }

  badgeTargetConnected(badge) {
    const count = Number(badge.dataset.count || 0)
    if (this.lastCount !== undefined && count > this.lastCount) this.flash(badge, "chats-badge--bumped", 200)
    this.lastCount = count
  }

  // Debounced while open; marked stale while closed (it reloads on open).
  // A list that never loaded will load fresh when it is first shown.
  refreshList() {
    if (!this.hasListTarget || !this.listTarget.hasAttribute("complete")) return

    if (!this.panelTarget.open) {
      this.listStale = true
      return
    }
    clearTimeout(this.listTimer)
    this.listTimer = setTimeout(() => this.listTarget.reload(), LIST_DELAY_MS)
  }

  panelToggled() {
    if (this.panelTarget.open && this.listStale) {
      this.listStale = false
      this.listTarget.reload()
    }
    if (!this.panelTarget.open && this.compact) {
      this.windowTargets.forEach((frame) => frame.classList.remove(FRONT))
    }
    this.syncSheet()
    this.save()
  }

  // A send from one of our windows: the draft is gone, the list reorders.
  sent(event) {
    if (!event.detail?.success) return

    const frame = this.frameOf(event.target)
    if (!frame) return
    this.forgetDraft(frame.dataset.conversationId)
    this.refreshList()
  }

  typed(event) {
    const frame = this.frameOf(event.target)
    if (!frame || !event.target.matches(".chats-composer__input")) return

    clearTimeout(frame.draftTimer)
    frame.draftTimer = setTimeout(() => this.keepDraft(frame), DRAFT_DELAY_MS)
  }

  // --- Engagement --------------------------------------------------------------

  // Focus, a press, a wheel or a touch inside a window: the viewer is with
  // it. It becomes the most recently used, and an expanded one may read.
  engage(event) {
    const frame = this.frameOf(event.target)
    if (!frame) return

    frame.dataset.usedAt = String(Date.now())
    if (!this.minimized(frame)) this.activate(frame)
  }

  activate(frame) {
    const waiting = !this.engaged(frame) || frame.classList.contains(UNREAD)
    frame.dataset.chatsActive = "true"
    frame.classList.remove(UNREAD)
    delete frame.dataset.unread
    this.syncControls(frame)
    // The thread controller reads what waited for the viewer.
    if (waiting) frame.dispatchEvent(new CustomEvent("chats:activated"))
  }

  engaged(frame) {
    return frame.dataset.chatsActive === "true"
  }

  // --- Window controls -------------------------------------------------------

  // The title button and the – button: fold or unfold. Unfolding is the
  // viewer turning to the window, so it counts as engaging with it.
  minimize(event) {
    const frame = this.frameOf(event.target)
    if (!frame || this.compact) return

    if (this.minimized(frame)) {
      this.show(frame)
    } else {
      this.setMinimized(frame, true)
    }
  }

  close(event) {
    this.closeWindow(this.frameOf(event.target))
  }

  // Phones: back to the list the window came from.
  back(event) {
    const frame = this.frameOf(event.target)
    frame?.classList.remove(FRONT)
    this.panelTarget.open = true
    this.syncSheet()
    this.summary.focus()
  }

  retry(event) {
    const frame = this.frameOf(event.target)
    if (!frame) return

    frame.replaceChildren(this.shell("loading", this.rowName(frame.dataset.conversationId)))
    frame.reload()
  }

  // Closed by the viewer: it won't pop open again for five minutes, and the
  // focus goes back where they came from.
  closeWindow(frame) {
    if (!frame) return

    const hadFocus = frame.contains(document.activeElement)
    const opener = this.openers.get(frame)
    this.closed = { ...this.closed, [frame.dataset.conversationId]: Date.now() }
    this.removeWindow(frame)
    this.save()

    if (hadFocus) (opener?.isConnected ? opener : this.summary).focus()
  }

  // Every way a window goes keeps what was typed in it.
  removeWindow(frame) {
    this.keepDraft(frame)
    frame.remove()
    this.markOpenRows()
  }

  setMinimized(frame, minimized) {
    if (this.minimized(frame) === minimized) return

    frame.classList.toggle(MINIMIZED, minimized)
    this.syncControls(frame)
    this.save()
  }

  // What depends on a window's state inside content the server may have
  // just replaced: the disclosure state, the folded body taken out of the
  // tab order, the waiting count.
  syncControls(frame) {
    const minimized = this.minimized(frame)
    frame.querySelector(".chats-window__title")?.setAttribute("aria-expanded", String(!minimized))
    frame.querySelectorAll(".chats-thread--window > :not(.chats-window__header), .chats-window__status")
      .forEach((part) => { part.inert = minimized })

    const badge = frame.querySelector("[data-chats-dock-window-unread]")
    if (badge) {
      const count = Number(frame.dataset.unread || 0)
      badge.hidden = !count
      badge.textContent = count > 99 ? "99+" : String(count || "")
      badge.title = count ? this.unreadLabel(count) : ""
    }
  }

  frameLoaded(event) {
    const frame = event.target
    if (this.hasListTarget && frame === this.listTarget) return this.markOpenRows()
    if (!this.windowTargets.includes(frame)) return

    this.syncControls(frame)
    this.restoreDraft(frame)
  }

  // A window whose conversation is gone for this viewer (they left, a block
  // hides it) answers 404 without its frame: close it quietly, instead of
  // Turbo printing "Content missing" into the dock.
  frameMissing(event) {
    if (!this.windowTargets.includes(event.target)) return

    event.preventDefault()
    event.target.remove()
    this.markOpenRows()
    this.save()
  }

  // No answer at all (offline): say so, with a way to try again.
  frameFailed(event) {
    const frame = event.target
    if (!this.windowTargets.includes(frame)) return

    frame.replaceChildren(this.shell("failed", this.rowName(frame.dataset.conversationId)))
  }

  focusInside(frame) {
    // On a phone the keyboard would cover the history they came to read.
    const selector = this.compact ? ".chats-window__back" : ".chats-composer__input"
    const focus = () => frame.querySelector(selector)?.focus({ preventScroll: true })

    if (frame.querySelector(".chats-thread--window")) {
      focus()
    } else {
      frame.addEventListener("turbo:frame-load", focus, { once: true })
    }
  }

  // --- Keyboard --------------------------------------------------------------------

  keydown(event) {
    if (event.key !== "Escape" || event.defaultPrevented) return
    // The thread's long-press popup and photo preview close themselves.
    if (event.target.closest(".chats-popup, .chats-attachment-preview")) return
    if (this.element.querySelector(".chats-popup:not([hidden]), .chats-attachment-preview:not([hidden])")) return

    const menu = event.target.closest("details.chats-window__menu[open]")
    if (menu) {
      menu.open = false
      menu.querySelector("summary")?.focus()
      return
    }

    const frame = this.frameOf(event.target)
    if (this.compact) {
      if (frame?.classList.contains(FRONT)) return this.back({ target: frame })
      if (this.panelTarget.open) {
        this.panelTarget.open = false
        this.summary.focus()
      }
      return
    }

    if (frame && !this.minimized(frame)) {
      this.setMinimized(frame, true)
      frame.querySelector(".chats-window__title")?.focus()
    } else if (!frame && this.panelTarget.open) {
      this.panelTarget.open = false
      this.summary.focus()
    }
  }

  // --- Pages -------------------------------------------------------------------------

  // After every visit: hidden on the pages that ask for it, and no window
  // for a conversation the page itself now renders.
  pageChanged() {
    const hide = !this.everywhereValue &&
      Array.from(document.querySelectorAll("[data-chats-dock-hide]")).some((node) => !this.element.contains(node))
    this.element.hidden = hide
    if (hide) this.panelTarget.open = false

    this.windowTargets.forEach((frame) => {
      if (this.renderedOnPage(frame.dataset.conversationId)) this.removeWindow(frame)
    })
    this.markOpenRows()
    this.syncSheet()
    this.save()
  }

  // A row whose conversation is open in a window says so.
  markOpenRows() {
    if (!this.hasListTarget) return

    this.listTarget.querySelectorAll("[data-chats-dock-conversation-id]").forEach((row) => {
      if (this.windowFor(String(row.dataset.chatsDockConversationId))) {
        row.setAttribute("aria-current", "true")
      } else {
        row.removeAttribute("aria-current")
      }
    })
  }

  // --- Memory ------------------------------------------------------------------------
  //
  // localStorage may be missing, full, or refuse access (private modes,
  // blocked site data): the dock then simply forgets. Every access is
  // guarded.

  get storageKey() {
    return `chats:dock:v1:${this.messagerValue}`
  }

  save() {
    const saved = this.read(this.storageKey) || {}
    this.write(this.storageKey, {
      // The sheet always starts closed: only the dock's panel is remembered.
      panel: this.compact ? Boolean(saved.panel) : this.panelTarget.open,
      windows: this.windowTargets.map((frame) => ({
        id: frame.dataset.conversationId,
        minimized: this.minimized(frame),
        usedAt: Number(frame.dataset.usedAt || 0)
      })),
      closed: this.freshClosed()
    })
  }

  // Once per page load (a Turbo visit keeps the live element and skips it):
  // the windows in their saved order, as many as fit now, not engaged.
  restore() {
    const saved = this.read(this.storageKey)
    if (!saved || this.windowTargets.length > 0) return

    const windows = Array.isArray(saved.windows) ? saved.windows.filter((entry) => entry?.id) : []
    windows.slice(-this.fit).forEach((entry) => {
      const frame = this.openWindow(String(entry.id), { minimized: Boolean(entry.minimized), active: false })
      if (frame && entry.usedAt) frame.dataset.usedAt = String(entry.usedAt)
    })
    if (!this.compact && saved.panel) this.panelTarget.open = true
  }

  recentlyClosed(id) {
    return Date.now() - (this.closed?.[id] || 0) < NO_REPOP_MS
  }

  freshClosed() {
    const now = Date.now()
    const closed = this.closed && typeof this.closed === "object" ? this.closed : {}
    return Object.fromEntries(Object.entries(closed).filter(([, at]) => now - Number(at) < NO_REPOP_MS))
  }

  draftKey(id) {
    return `chats:draft:${this.messagerValue}:${id}`
  }

  keepDraft(frame) {
    const input = frame.querySelector(".chats-composer__input")
    if (!input) return

    if (input.value.trim()) {
      this.write(this.draftKey(frame.dataset.conversationId), { text: input.value, at: Date.now() })
    } else {
      this.forgetDraft(frame.dataset.conversationId)
    }
  }

  restoreDraft(frame) {
    const input = frame.querySelector(".chats-composer__input")
    const draft = this.read(this.draftKey(frame.dataset.conversationId))
    if (!input || !draft || input.value) return

    if (typeof draft.text === "string" && Date.now() - (draft.at || 0) < DRAFT_TTL_MS) input.value = draft.text
    this.forgetDraft(frame.dataset.conversationId)
  }

  forgetDraft(id) {
    try {
      window.localStorage.removeItem(this.draftKey(id))
    } catch {
      // nothing was remembered
    }
  }

  read(key) {
    try {
      return JSON.parse(window.localStorage.getItem(key) || "null")
    } catch {
      return null
    }
  }

  write(key, value) {
    try {
      window.localStorage.setItem(key, JSON.stringify(value))
    } catch {
      // nothing to remember with
    }
  }

  // --- Layout ------------------------------------------------------------------------

  // The phone layout is one media query in chats.css (so it holds before
  // this controller connects, and without JavaScript); the same query
  // decides the behaviour here.
  layout = () => {
    const compact = this.media.matches
    if (this.compact === true && !compact) this.windowTargets.forEach((frame) => frame.classList.remove(FRONT))
    if (this.compact === false && compact) this.panelTarget.open = false

    this.compact = compact
    this.element.dataset.mode = compact ? "sheet" : "dock"
    this.fitViewport()
    this.resized()
    this.syncSheet()
  }

  // A narrower viewport closes windows down to what fits, least recently
  // used first, never the focused one.
  resized = () => {
    if (this.compact) return
    cancelAnimationFrame(this.resizeFrame)
    this.resizeFrame = requestAnimationFrame(() => {
      if (this.windowTargets.length > this.fit && this.makeRoom(this.focusedWindow(), { force: false })) this.save()
    })
  }

  // Full-screen on a phone means the VISIBLE viewport: with the keyboard up
  // it is shorter than 100dvh, and the composer must sit on the keys.
  fitViewport = () => {
    const viewport = window.visualViewport
    if (!viewport) return

    this.element.style.setProperty("--chats-vvh", `${viewport.height}px`)
    this.element.style.setProperty("--chats-vv-top", `${viewport.offsetTop}px`)
    this.element.classList.toggle("chats-dock--keyboard", this.compact && window.innerHeight - viewport.height > 150)
  }

  // On a phone, an open sheet is modal: the page behind can't scroll or
  // take the focus.
  syncSheet() {
    const open = Boolean(this.compact) && !this.element.hidden &&
      (this.panelTarget.open || this.windowTargets.some((frame) => frame.classList.contains(FRONT)))
    document.documentElement.classList.toggle("chats-dock-sheet-open", open)
    if (open) {
      if (this.inerted.length) return
      this.inerted = Array.from(document.body.children).filter((node) => node !== this.element && !node.inert)
      this.inerted.forEach((node) => { node.inert = true })
    } else {
      this.releaseSheet()
    }
  }

  releaseSheet() {
    this.inerted?.forEach((node) => { node.inert = false })
    this.inerted = []
    if (this.compact !== undefined) document.documentElement.classList.remove("chats-dock-sheet-open")
  }

  // --- Lookups ---------------------------------------------------------------------

  get summary() {
    return this.panelTarget.querySelector("summary")
  }

  windowFor(id) {
    return this.windowTargets.find((frame) => frame.dataset.conversationId === id)
  }

  frameOf(element) {
    return element?.closest?.(".chats-window")
  }

  minimized(frame) {
    return frame.classList.contains(MINIMIZED)
  }

  focusedWindow() {
    return this.windowTargets.find((frame) => frame.contains(document.activeElement)) || null
  }

  leastRecentlyUsed(keeping) {
    return this.windowTargets
      .filter((frame) => frame !== keeping && !frame.contains(document.activeElement))
      .sort((a, b) => Number(a.dataset.usedAt || 0) - Number(b.dataset.usedAt || 0))[0]
  }

  oldest(keeping) {
    return this.windowTargets.find((frame) => frame !== keeping)
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

  // The name a row shows for a conversation, for a window's shell header.
  rowName(id) {
    const row = this.hasListTarget && this.listTarget.querySelector(`[data-chats-dock-conversation-id="${CSS.escape(id)}"]`)
    return row?.querySelector(".chats-row__title")?.textContent?.trim() || null
  }

  shell(state, name) {
    const template = state === "failed" ? this.failedShellTarget : this.loadingShellTarget
    const content = template.content.cloneNode(true)
    if (name) {
      const label = content.querySelector("[data-chats-dock-name]")
      if (label) label.textContent = name
    }
    return content
  }

  unreadLabel(count) {
    try {
      const forms = JSON.parse(this.windowUnreadValue || "{}")
      return (count === 1 ? forms.one : forms.other)?.replace("%{count}", count) || ""
    } catch {
      return ""
    }
  }

  pixels(property, fallback) {
    const value = getComputedStyle(this.element).getPropertyValue(property).trim()
    return value.endsWith("px") ? parseFloat(value) : fallback
  }

  flash(element, className, duration) {
    element.classList.add(className)
    setTimeout(() => element.classList.remove(className), duration)
  }
}
