import { Controller } from "@hotwired/stimulus"
import { afterRendering, cancelStreamsFor, recoverMissedBroadcasts, renderStreamFrom } from "chats/recovery"

// Stale-thread catch-up + DOM budget (both patterns from Basecamp's
// Campfire, https://github.com/basecamp/once-campfire — its
// refresh_room_controller and message_paginator):
//   * catch up on what the stream missed whenever chats/recovery says it
//     may have (a reconnect, a return after 10 seconds hidden, the network
//     back, a page restored from the back/forward cache or a Turbo
//     snapshot): GET #refresh?since= appends, replaces and removes exactly
//     what changed, so the composer, its draft and the scroll position are
//     never touched;
//   * cap rendered bubbles so day-long sessions in a busy group don't
//     grow the DOM unboundedly (trimmed history stays reachable — the
//     pagination anchor is rebuilt to re-fetch it on scroll-up).
// Long-press tuning: Telegram-ish. The move tolerance keeps a scroll
// gesture from ever reading as a press.
const LONG_PRESS_MS = 450
const PRESS_MOVE_TOLERANCE_PX = 12
// Teardown must outlive the close morph (260ms in chats.css and in hosts'
// ejected styles) or the clone is yanked mid-flight and the bubble snaps the
// last few pixels home. Keep this a hair ABOVE the CSS transform duration.
const POPUP_TRANSITION_MS = 280
const MAX_RENDERED_MESSAGES = 300
// Keep in step with ConversationsController::CURSOR_IDS_LIMIT.
const CURSOR_IDS = 200

// A name for one render of a thread.
const newRender = () => `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 8)}`
const TRIM_LEEWAY = 20

// chats--thread: everything live about an open conversation.
//
// Bubbles arrive VIEWER-AGNOSTIC (one broadcast render is shared by every
// subscriber — see Chats::Broadcasts), so this controller is what makes the
// thread personal:
//
//   * own-vs-other alignment    compare each bubble's data-sender-key to our
//                               me-value; tag own bubbles with
//                               .chats-message--own (CSS does the rest,
//                               including revealing the edit/delete actions —
//                               cosmetic only; the server authorizes for real)
//   * stick-to-bottom           autoscroll on new messages when the viewer is
//                               already near the bottom (never yank them up
//                               mid-history-read)
//   * mark-as-read              debounce a POST to #read when foreign messages
//                               arrive while the thread is on screen — that
//                               POST advances our read horizon and broadcasts
//                               fresh read-state to everyone. Only while the
//                               viewer can actually be reading: a visible tab,
//                               a thread with room to show itself (a minimized
//                               dock window has none), and — inside a dock
//                               window — one the viewer is engaged with (the
//                               dock's `data-chats-active` gate; a window that
//                               popped open by itself waits for a focus, a
//                               press or a scroll). A dock window is rendered
//                               unread (`readPending`) and reads the same way.
//   * sent / seen receipts      derive per-message ticks client-side from the
//                               broadcast read-state payload
//   * day separators            recalculate local-calendar markers after the
//                               initial render, lazy pagination, and appends
//   * typing indicator          a Turbo Stream CUSTOM ACTION (no Action Cable
//                               channel of its own) — see registration below
//
// Registered automatically by stimulus-rails' eagerLoadControllersFrom
// because the engine pins this file under controllers/chats/ (identifier:
// "chats--thread"). See Chats::Engine's importmap initializer.
export default class extends Controller {
  static targets = [
    "scroller",
    "message",
    "typing",
    "readState",
    "popup",
    "popupReactions",
    "popupBubble",
    "popupMenu",
    "attachmentDialog",
    "attachmentImage"
  ]
  static values = {
    me: String,
    readUrl: String,
    refreshUrl: String,
    threadUrl: String,
    sentLabel: String,
    seenLabel: String,
    todayLabel: String,
    yesterdayLabel: String,
    daySeparatorClass: { type: String, default: "chats-day-separator" },
    typingSuffix: String,
    copiedLabel: String,
    group: Boolean,
    readPending: Boolean
  }

  connect() {
    this.registerTypingStreamAction()
    this.registerPruneStreamAction()
    this.registerCaughtUpStreamAction()
    this.element.dataset.chatsRender ||= newRender()
    this.caughtUp({ detail: this.storedCursors() || this.cursorsOfRender() })
    // The dock's engagement gate: the window frame around a dock thread.
    // No gate (the thread page) means always engaged.
    this.gate = this.element.closest("[data-chats-active]")
    this.gate?.addEventListener("chats:activated", this.flushPendingRead)

    // targetConnected fires for every server-rendered bubble right after
    // connect; this flag keeps the initial flood from triggering N scrolls
    // and N read POSTs.
    this.booting = true
    requestAnimationFrame(() => {
      this.booting = false
      this.scrollToBottom()
      this.renderReceipts()
      this.renderDaySeparators()
      this.renderMessageGroups()
      if (this.readPendingValue) this.queueRead()
    })

    if (this.hasTypingTarget) {
      this.typingTarget.addEventListener("chats:typing", this.showTyping)
    }
    document.addEventListener("visibilitychange", this.visibilityChanged)
    // Capture phase: the synthetic click that follows a long-press release
    // must never reach the pressed bubble's links/forms once the popup is
    // up — one-shot, armed by openPopup().
    this.suppressClickCapture = (event) => {
      if (!this.suppressNextClick) return
      this.suppressNextClick = false
      // Only the release-click on the PRESSED region is synthetic — taps
      // inside the popup (a menu item can be the very next click after a
      // right-click open) are real and must pass.
      if (this.hasPopupTarget && this.popupTarget.contains(event.target)) return
      event.preventDefault()
      event.stopPropagation()
    }
    this.element.addEventListener("click", this.suppressClickCapture, true)
    this.element.addEventListener("chats:prune", this.prune)
    this.element.addEventListener("chats:caught-up", this.caughtUp)
    this.stopRecovery = recoverMissedBroadcasts(this.element, () => this.refreshThread())
    this.watchScreenPresence()
  }

  disconnect() {
    if (this.hasTypingTarget) {
      this.typingTarget.removeEventListener("chats:typing", this.showTyping)
    }
    document.removeEventListener("visibilitychange", this.visibilityChanged)
    clearTimeout(this.readTimer)
    this.stopRecovery?.()
    // What this render asked for is not wanted any more — once it is really
    // gone. A Turbo visit carries the dock from page to page by taking it
    // off the page and putting it back once the new body is in: a window's
    // thread is away for the length of that render and keeps everything,
    // its answer on the way included. Still off the page once the render is
    // over is a thread that went away (another page, a window reloaded or
    // closed).
    afterRendering().then(() => { if (!this.element.isConnected) cancelStreamsFor(this.element) })
    this.element.removeEventListener("chats:prune", this.prune)
    this.element.removeEventListener("chats:caught-up", this.caughtUp)
    this.presenceObserver?.disconnect()
    this.gate?.removeEventListener("chats:activated", this.flushPendingRead)
    this.element.removeEventListener("click", this.suppressClickCapture, true)
    clearTimeout(this.pressTimer)
    this.teardownPopup()
    clearTimeout(this.typingTimer)
    cancelAnimationFrame(this.daySeparatorFrame)
    cancelAnimationFrame(this.messageGroupFrame)
    document.documentElement.classList.remove("chats-attachment-preview-open")
  }

  // --- Bubbles ---------------------------------------------------------------

  messageTargetConnected(element) {
    this.trackLegacyCursor(element)
    this.classify(element)
    if (this.booting) return
    // Live appends can land out of order (multi-worker hosts broadcast from
    // concurrent jobs). Re-slot the bubble if its predecessor is newer; the
    // move re-fires this callback, which then proceeds in order.
    if (this.ensureChronological(element)) return

    // Bubbles (re)connect for three reasons: a new message arriving at the
    // tail, an existing bubble REPLACED in place (edit and tombstone
    // broadcasts re-render the same dom_id), and older history paginating
    // in above. Only a TAIL arrival may move the viewport — autoscrolling
    // on a replace yanked editors to the bottom as if they'd sent a new
    // message, away from the bubble they just edited mid-history.
    const latest = this.messageTargets[this.messageTargets.length - 1] === element
    const own = element.dataset.senderKey === this.meValue
    if (latest && (own || this.nearBottom())) this.scrollToBottom()
    if (!own) {
      // Typing pings are ephemeral and intentionally not coupled to message
      // persistence. Once a real message from that sender arrives, the old
      // "Alice is typing…" signal is stale and should disappear immediately
      // instead of waiting for the timeout. Turbo custom actions are the
      // transport here: https://turbo.hotwired.dev/reference/streams#custom-actions
      this.hideTypingFor(element.dataset.senderKey)
      this.queueRead()
    }
    this.renderReceipts()
    this.scheduleDaySeparators()
    this.scheduleMessageGroups()
    this.trimExcessMessages()
  }

  classify(element) {
    const own = element.dataset.senderKey && element.dataset.senderKey === this.meValue
    element.classList.toggle("chats-message--own", own)

    const receipt = element.querySelector("[data-chats-message-receipt]")
    const label = element.querySelector("[data-chats-message-receipt-label]")
    if (receipt && !own) {
      receipt.hidden = true
      receipt.textContent = ""
      delete receipt.dataset.state
    }
    if (label && !own) {
      label.hidden = true
      label.textContent = ""
    }
  }

  // --- Read state ("Seen") -----------------------------------------------------

  readStateTargetConnected() {
    if (!this.booting) this.renderReceipts()
  }

  renderReceipts() {
    if (!this.sentLabelValue) return

    const ownMessages = this.messageTargets.filter(
      (element) => element.dataset.senderKey === this.meValue
    )
    ownMessages.forEach((message) => this.setReceipt(message, false))
    if (!this.seenLabelValue || !this.hasReadStateTarget) return

    let horizons
    try {
      horizons = JSON.parse(this.readStateTarget.dataset.horizons || "{}")
    } catch {
      return
    }

    // Other participants' read horizons (ISO8601 strings — lexicographic
    // comparison is chronological for a fixed format). "Seen" means seen by
    // EVERYONE else, so the effective horizon is the minimum.
    const others = Object.entries(horizons)
      .filter(([key]) => key !== this.meValue)
      .map(([, readAt]) => readAt)
    if (others.length === 0 || others.some((readAt) => !readAt)) return
    const horizon = others.reduce((min, readAt) => (readAt < min ? readAt : min))

    ownMessages.forEach((message) => {
      this.setReceipt(message, message.dataset.timestamp <= horizon)
    })
  }

  setReceipt(message, seen) {
    const receipt = message.querySelector("[data-chats-message-receipt]")
    if (!receipt) return

    receipt.textContent = seen ? "✓✓" : "✓"
    receipt.dataset.state = seen ? "seen" : "sent"
    receipt.hidden = false

    const label = message.querySelector("[data-chats-message-receipt-label]")
    if (label) {
      label.textContent = seen ? this.seenLabelValue : this.sentLabelValue
      label.hidden = false
    }
  }

  // --- Day separators ---------------------------------------------------------

  scheduleDaySeparators() {
    cancelAnimationFrame(this.daySeparatorFrame)
    this.daySeparatorFrame = requestAnimationFrame(() => this.renderDaySeparators())
  }

  renderDaySeparators() {
    this.element.querySelectorAll("[data-chats-day-separator]").forEach((separator) => separator.remove())

    let previousDay
    this.messageTargets.forEach((message) => {
      const date = new Date(message.dataset.timestamp)
      if (Number.isNaN(date.getTime())) return

      const day = this.dayKey(date)
      if (day !== previousDay) message.before(this.daySeparator(date))
      previousDay = day
    })
  }

  daySeparator(date) {
    const separator = document.createElement("div")
    separator.className = this.daySeparatorClassValue
    separator.dataset.chatsDaySeparator = ""
    separator.textContent = this.dayLabel(date)
    return separator
  }

  dayLabel(date) {
    const today = new Date()
    const yesterday = new Date(today)
    yesterday.setDate(today.getDate() - 1)

    if (this.dayKey(date) === this.dayKey(today) && this.todayLabelValue) return this.todayLabelValue
    if (this.dayKey(date) === this.dayKey(yesterday) && this.yesterdayLabelValue) return this.yesterdayLabelValue

    const options = { day: "numeric", month: "long" }
    if (date.getFullYear() !== today.getFullYear()) options.year = "numeric"
    return new Intl.DateTimeFormat(document.documentElement.lang || undefined, options).format(date)
  }

  dayKey(date) {
    return [date.getFullYear(), date.getMonth(), date.getDate()].join("-")
  }

  // --- Consecutive-message grouping ---------------------------------------------

  scheduleMessageGroups() {
    cancelAnimationFrame(this.messageGroupFrame)
    this.messageGroupFrame = requestAnimationFrame(() => this.renderMessageGroups())
  }

  renderMessageGroups() {
    const messages = this.messageTargets

    messages.forEach((message, index) => {
      const previous = messages[index - 1]
      const following = messages[index + 1]

      message.classList.toggle("chats-message--continuation", this.sameMessageGroup(previous, message))
      message.classList.toggle("chats-message--followed", this.sameMessageGroup(message, following))
    })
  }

  sameMessageGroup(first, second) {
    if (!first || !second || !first.dataset.senderKey || !second.dataset.senderKey) return false
    if (first.dataset.senderKey !== second.dataset.senderKey) return false

    const firstDate = new Date(first.dataset.timestamp)
    const secondDate = new Date(second.dataset.timestamp)
    if (Number.isNaN(firstDate.getTime()) || Number.isNaN(secondDate.getTime())) return false

    return this.dayKey(firstDate) === this.dayKey(secondDate)
  }

  // --- Attachment preview --------------------------------------------------------

  openAttachment(event) {
    event.preventDefault()
    if (!this.hasAttachmentDialogTarget || !this.hasAttachmentImageTarget) return

    const link = event.currentTarget

    // Media takes the whole screen: drop composer focus first so the
    // on-screen keyboard slides away instead of overlapping the preview
    // (matches every messaging app's behavior).
    document.activeElement?.blur?.()

    this.attachmentImageTarget.src = link.href
    this.attachmentImageTarget.alt = link.querySelector("img")?.alt || ""
    this.attachmentDialogTarget.hidden = false
    document.documentElement.classList.add("chats-attachment-preview-open")
    this.attachmentDialogTarget.focus({ preventScroll: true })
  }

  closeAttachment() {
    if (!this.hasAttachmentDialogTarget) return

    this.attachmentDialogTarget.hidden = true
    document.documentElement.classList.remove("chats-attachment-preview-open")
    this.resetAttachment()
  }

  closeAttachmentFromBackdrop(event) {
    if (event.target === event.currentTarget) this.closeAttachment()
  }

  resetAttachment() {
    if (this.hasAttachmentImageTarget) {
      this.attachmentImageTarget.removeAttribute("src")
      this.attachmentImageTarget.alt = ""
    }
  }

  // --- Mark-as-read ------------------------------------------------------------

  queueRead() {
    if (!this.canRead()) {
      this.pendingRead = true
      return
    }
    clearTimeout(this.readTimer)
    this.readTimer = setTimeout(() => this.postRead(), 700)
  }

  // A read that waited for the tab to be seen happens when it is. (What the
  // tab missed while hidden is chats/recovery's to fetch.)
  visibilityChanged = () => {
    if (document.visibilityState === "visible" && this.pendingRead) {
      this.pendingRead = false
      this.queueRead()
    }
  }

  // Whether the viewer can be reading this thread right now.
  canRead() {
    return document.visibilityState === "visible" && this.engaged() && this.onScreen()
  }

  // The thread has room to show itself. Geometry alone, for any host that
  // collapses a thread its own way; the dock's own state is engaged()'s job.
  onScreen() {
    return !this.hasScrollerTarget || this.scrollerTarget.clientHeight > 0
  }

  // Inside a dock window, what the dock says, explicitly: the window is
  // neither minimized (data-chats-minimized) nor waiting for the viewer to
  // turn to it (data-chats-active="false"). Geometry can't be trusted for
  // the first: a folded window's scroller keeps whatever padding a host
  // gives it. No gate (the thread page): always engaged.
  engaged() {
    if (!this.gate) return true

    return this.gate.dataset.chatsActive !== "false" && !this.gate.hasAttribute("data-chats-minimized")
  }

  // A read that waited for the thread to be seen happens the moment it is:
  // a minimized window expanding gives its scroller a height, and the dock
  // says when the viewer turns to a window. It lands on the newest message,
  // which is what arrived.
  flushPendingRead = () => {
    if (!this.pendingRead || !this.canRead()) return
    this.pendingRead = false
    this.scrollToBottom()
    this.queueRead()
  }

  watchScreenPresence() {
    if (!this.hasScrollerTarget || typeof ResizeObserver === "undefined") return

    this.presenceObserver = new ResizeObserver(this.flushPendingRead)
    this.presenceObserver.observe(this.scrollerTarget)
  }

  postRead() {
    if (!this.readUrlValue) return
    // Asked again when the timer fires: the window may have been minimized
    // (or the tab hidden) in the 700ms since the message arrived.
    if (!this.canRead()) {
      this.pendingRead = true
      return
    }
    fetch(this.readUrlValue, {
      method: "POST",
      headers: { "X-CSRF-Token": csrfToken(), Accept: "application/json" }
    }).catch(() => {})
  }

  // --- Typing indicator ---------------------------------------------------------

  // The broadcast arrives as a <turbo-stream action="chats_typing"> targeting
  // our typing element; the registered action re-dispatches it as a DOM
  // event so the controller (not a global) owns presentation + timeout.
  registerTypingStreamAction() {
    const Turbo = window.Turbo
    if (!Turbo || Turbo.StreamActions.chats_typing) return

    Turbo.StreamActions.chats_typing = function () {
      this.targetElements.forEach((target) => {
        target.dispatchEvent(
          new CustomEvent("chats:typing", {
            detail: {
              name: this.getAttribute("data-name"),
              key: this.getAttribute("data-key")
            }
          })
        )
      })
    }
  }

  showTyping = (event) => {
    const { name, key } = event.detail
    if (key === this.meValue) return // our own echo

    const wasHidden = this.typingTarget.hidden
    this.typingKey = key
    this.typingTarget.textContent = `${name} ${this.typingSuffixValue}`
    this.typingTarget.hidden = false
    if (wasHidden && this.nearBottom()) this.scrollToBottom()

    clearTimeout(this.typingTimer)
    this.typingTimer = setTimeout(() => {
      this.typingTarget.hidden = true
      this.typingKey = null
    }, 4000)
  }

  hideTypingFor(key) {
    if (!this.hasTypingTarget) return
    if (key && this.typingKey && this.typingKey !== key) return

    clearTimeout(this.typingTimer)
    this.typingTarget.hidden = true
    this.typingTarget.textContent = ""
    this.typingKey = null
  }

  // --- Scrolling ----------------------------------------------------------------

  nearBottom() {
    if (!this.hasScrollerTarget) return true
    const el = this.scrollerTarget
    return el.scrollHeight - el.scrollTop - el.clientHeight < 120
  }

  scrollToBottom() {
    if (!this.hasScrollerTarget) return
    this.scrollerTarget.scrollTop = this.scrollerTarget.scrollHeight
  }

  // --- Stale-thread refresh (catch up after sleep/disconnect) --------------------

  // Two cursors, because "new" and "changed" are different questions: the
  // newest creation (`after`: anything newer is appended) and the newest
  // change (`changed`: anything changed since is replaced). One can't
  // answer both: a message created at 10:15 and missed, while a bubble on
  // screen was edited at 10:20, is older than the newest change. Each is a
  // moment to the microsecond the database keeps (an integer below 2^53,
  // exact as a Number).
  //
  // They are RECONCILED moments: how far the thread knows it has
  // everything. A complete render sets them (the page, a window, a history
  // re-render: the server sends those with it), and so does a catch-up
  // that arrived (the chats_caught_up action); a live bubble never moves
  // them, because it can arrive past one that was missed (a message missed
  // at 10:15, then one live at 10:20: a cursor at 10:20 would skip 10:15
  // for good). What arrived live is named instead, so it isn't sent again:
  // every bubble on screen created since `after`, and every one whose
  // version is exactly the `changed` moment. They live on the element
  // (data-chats-reconciled): the dock moves its windows, and a Turbo
  // snapshot is restored, without losing them.
  cursorsOfRender() {
    const created = this.messageTargets.map((message) => Number(message.dataset.createdAtUs || 0))
    const updated = this.messageTargets.map((message) => Number(message.dataset.updatedAtUs || 0))
    const changed = Math.max(0, ...updated)
    return {
      after: Math.max(0, ...created),
      changed,
      changedIds: this.messageTargets.filter((_, index) => updated[index] === changed).map((message) => message.dataset.messageId)
    }
  }

  // An answer carries the render it was asked from (`render`): one for an
  // earlier render of this conversation (the page or the window rendered it
  // again while the answer was on its way) would move the new render's
  // cursors to the old one's, and is ignored.
  caughtUp = (event) => {
    const { render, ...cursors } = event.detail
    if (render && render !== this.element.dataset.chatsRender) return

    this.reconciled = cursors
    this.element.dataset.chatsReconciled = JSON.stringify(cursors)
  }

  storedCursors() {
    try {
      return JSON.parse(this.element.dataset.chatsReconciled || "null")
    } catch {
      return null
    }
  }

  // Bubbles ejected before they carried the cursors above: the one
  // millisecond cursor they had, which moves with every bubble.
  trackLegacyCursor(element) {
    const legacy = Number(element.dataset.updatedAtMs || 0)
    if (legacy > (this.legacyCursor || 0)) this.legacyCursor = legacy
  }

  // What the stream missed: messages created after the reconciled moment
  // and not on screen (appended), ones on screen changed since (replaced:
  // edits, tombstones, reactions), the read state, and — when messages are
  // hard-deleted — which rendered bubbles still exist. An empty thread asks
  // from the epoch: its first message may be the one it missed. `from` is
  // the oldest rendered bubble, so the server can name every bubble that
  // should be on screen. A thread more than a page behind, or naming more
  // than CURSOR_IDS bubbles, gets its history re-rendered at the latest
  // page instead (`history`: this thread's scroller has the id that takes
  // it; one ejected before it did gets a page refresh); it then opens at
  // the bottom, as a fresh thread does, and asks once more from there, for
  // anything that arrived live while the history was being re-rendered.
  refreshThread({ followUp = true } = {}) {
    if (!this.refreshUrlValue) return

    const params = new URLSearchParams()
    if (this.legacyCursor && !this.messageTargets.some((message) => message.dataset.createdAtUs)) {
      params.set("since", this.legacyCursor)
    } else {
      const { after = 0, changed = 0, changedIds = [] } = this.reconciled || {}
      const afterIds = this.messageTargets
        .filter((message) => Number(message.dataset.createdAtUs || 0) >= after)
        .map((message) => message.dataset.messageId)
      const seenChanged = new Set(changedIds)
      this.messageTargets.forEach((message) => {
        if (Number(message.dataset.updatedAtUs || 0) === changed) seenChanged.add(message.dataset.messageId)
      })

      params.set("after", after)
      params.set("changed", changed)
      if (afterIds.length > CURSOR_IDS || seenChanged.size > CURSOR_IDS) {
        params.set("full", "1")
      } else {
        if (afterIds.length) params.set("after_ids", afterIds.join(","))
        if (seenChanged.size) params.set("changed_ids", [...seenChanged].join(","))
      }
    }
    const oldest = this.messageTargets[0]
    if (oldest?.dataset.createdAtUs) params.set("from", oldest.dataset.createdAtUs)
    if (this.hasScrollerTarget && this.scrollerTarget.id) params.set("history", "1")
    const last = this.messageTargets[this.messageTargets.length - 1]

    // Bound to this render of the thread (data-chats-render, renewed by
    // every complete render): an answer that arrives after the page or the
    // window rendered the conversation again is dropped unrendered.
    const render = this.element.dataset.chatsRender
    params.set("render", render)
    const current = () => this.element.isConnected && this.element.dataset.chatsRender === render

    // Resolves once Turbo has applied the answer, so `last` is gone by then
    // if the history was re-rendered.
    return renderStreamFrom(`${this.refreshUrlValue}?${params}`, {
      when: current,
      key: this.element,
      // Given up while a page render that ran past its bound had the thread
      // away, and asked again once that render ended with it back: catch up anew.
      retry: () => this.refreshThread()
    }).then((rendered) => {
      if (!rendered || !last || last.isConnected) return

      this.element.dataset.chatsRender = newRender() // the re-rendered history is a new render
      this.scrollToBottom()
      if (followUp) return this.refreshThread({ followUp: false })
    })
  }

  // A hard delete the stream missed: the bubble is gone from the server, so
  // it goes from here. Only bubbles created before `until`, which the server
  // sets a little before it listed what exists: a message whose insert had
  // not committed yet when it looked, and which then arrived live, is new,
  // not deleted.
  prune = (event) => {
    const present = new Set(event.detail.ids)
    this.messageTargets.forEach((message) => {
      if (Number(message.dataset.createdAtUs || Infinity) > event.detail.until) return
      if (!present.has(message.id)) message.remove()
    })
  }

  // The cursors a catch-up (or a history re-render) leaves the thread at.
  registerCaughtUpStreamAction() {
    const Turbo = window.Turbo
    if (!Turbo || Turbo.StreamActions.chats_caught_up) return

    Turbo.StreamActions.chats_caught_up = function () {
      const detail = {
        render: this.getAttribute("data-render") || null,
        after: Number(this.getAttribute("data-after") || 0),
        changed: Number(this.getAttribute("data-changed") || 0),
        changedIds: (this.getAttribute("data-changed-ids") || "").split(",").filter(Boolean)
      }
      this.targetElements.forEach((target) => {
        target.dispatchEvent(new CustomEvent("chats:caught-up", { bubbles: true, detail }))
      })
    }
  }

  registerPruneStreamAction() {
    const Turbo = window.Turbo
    if (!Turbo || Turbo.StreamActions.chats_prune) return

    Turbo.StreamActions.chats_prune = function () {
      const detail = {
        ids: (this.getAttribute("data-ids") || "").split(" ").filter(Boolean),
        until: Number(this.getAttribute("data-until") || 0)
      }
      this.targetElements.forEach((target) => {
        target.dispatchEvent(new CustomEvent("chats:prune", { bubbles: true, detail }))
      })
    }
  }

  // --- DOM budget -----------------------------------------------------------------

  // Day-long sessions in a busy group append without bound; past
  // MAX_RENDERED_MESSAGES (+ leeway, so we trim in batches instead of per
  // message) drop the oldest bubbles. Only when the viewer is parked at the
  // bottom — never yank history out from under someone reading it.
  trimExcessMessages() {
    const all = this.messageTargets
    if (all.length <= MAX_RENDERED_MESSAGES + TRIM_LEEWAY) return
    if (!this.nearBottom()) return

    all.slice(0, all.length - MAX_RENDERED_MESSAGES).forEach((element) => element.remove())

    // They're at the bottom of a 300+ message thread: any «new messages»
    // divider is long since consumed.
    this.element.querySelectorAll(".chats-thread__unread-line").forEach((line) => line.remove())

    this.rebuildPaginationAnchor()
    this.scheduleDaySeparators()
    this.scheduleMessageGroups()
  }

  // Trimmed history must stay REACHABLE: drop pagination frames that no
  // longer hold any bubbles (their lazy anchors point into ranges that no
  // longer line up), then plant a fresh lazy frame anchored at the new
  // oldest bubble — scrolling up re-fetches everything older, seamlessly,
  // through the exact same keyset endpoint the original chain used.
  rebuildPaginationAnchor() {
    if (!this.hasScrollerTarget) return

    this.scrollerTarget.querySelectorAll('turbo-frame[id^="chats_page_"]').forEach((frame) => {
      if (!frame.querySelector('[data-chats--thread-target="message"]')) frame.remove()
    })

    const oldest = this.messageTargets[0]
    if (!oldest || !this.threadUrlValue) return

    // dom_id format is "chats_message_<id>" — the record id is the tail.
    const messageId = oldest.id.split("_").pop()
    const frameId = `chats_page_${messageId}`
    if (!messageId || document.getElementById(frameId)) return

    const frame = document.createElement("turbo-frame")
    frame.id = frameId
    frame.setAttribute("loading", "lazy")
    const separator = this.threadUrlValue.includes("?") ? "&" : "?"
    frame.src = `${this.threadUrlValue}${separator}before=${messageId}`
    frame.innerHTML = '<div class="chats-loader"></div>'
    this.scrollerTarget.prepend(frame)
  }

  // --- Long-press message popup (Telegram-style) ----------------------------------
  //
  // Long-press (or right-click) a bubble: a clone of it morphs to the center
  // of the screen over a blurred glass backdrop, the reactions pill appears
  // above it and the contextual menu (copy / edit / delete / host-injected
  // items) below. NOTHING actionable renders inline on bubbles — the menu
  // content lives in each bubble's inert <template data-chats-message-menu>
  // and is cloned in here on open. The FLIP morph measures the bubble's
  // on-screen rect, mounts the clone at its centered slot, then transitions
  // the delta transform back to zero (and the reverse on close).

  pressStart(event) {
    if (this.popupOpenFor) return
    if (event.button !== undefined && event.button !== 0) return

    const bubble = event.target.closest(".chats-message")
    if (!bubble || !this.element.contains(bubble)) return
    // Buttons/fields keep their own press semantics, but LINKS must not
    // block the gesture — an image-attachment bubble is one big <a>, and
    // "long-press doesn't work on some messages" was exactly that. The
    // release-click on a link after the popup opened is swallowed by the
    // capture-phase suppressor installed in connect().
    if (event.target.closest("button, input, textarea, summary")) return

    this.pressOrigin = { x: event.clientX, y: event.clientY }
    clearTimeout(this.pressTimer)
    this.pressTimer = setTimeout(() => this.openPopup(bubble), LONG_PRESS_MS)
  }

  pressMove(event) {
    if (!this.pressTimer || !this.pressOrigin) return
    const dx = event.clientX - this.pressOrigin.x
    const dy = event.clientY - this.pressOrigin.y
    if (Math.hypot(dx, dy) > PRESS_MOVE_TOLERANCE_PX) this.cancelPress()
  }

  pressEnd() { this.cancelPress() }
  pressCancel() { this.cancelPress() }

  cancelPress() {
    clearTimeout(this.pressTimer)
    this.pressTimer = null
  }

  // Desktop parity + the Android long-press double-fire fix in one place:
  // right-click on a bubble IS the popup (no 450ms hold), and the native
  // context menu never appears over messages.
  contextMenu(event) {
    const bubble = event.target.closest(".chats-message")
    if (!bubble) return

    event.preventDefault()
    this.cancelPress()
    if (!this.popupOpenFor) this.openPopup(bubble)
  }

  openPopup(bubble) {
    this.cancelPress()
    if (!this.hasPopupTarget) return

    const template = bubble.querySelector("template[data-chats-message-menu]")
    const visual = bubble.querySelector(".chats-message__bubble") || bubble
    if (!template) return

    const own = bubble.dataset.senderKey === this.meValue
    const content = template.content.cloneNode(true)
    // Cosmetic visibility gates (the server still authorizes for real):
    // own-only items (edit/delete) vanish on foreign bubbles; other-only
    // items (e.g. a host report link — you don't report yourself) on own.
    if (!own) content.querySelectorAll("[data-chats-own-only]").forEach((node) => node.remove())
    if (own) content.querySelectorAll("[data-chats-other-only]").forEach((node) => node.remove())

    const reactions = content.querySelector(".chats-popup__reactions")
    const menu = content.querySelector(".chats-popup__menu")
    this.popupReactionsTarget.replaceChildren(...(reactions ? [reactions] : []))
    this.popupMenuTarget.replaceChildren(...(menu ? [menu] : []))

    // The lifted bubble: a visual clone (templates stripped) that morphs
    // from the original's rect into the centered stack slot.
    const originRect = visual.getBoundingClientRect()
    const clone = visual.cloneNode(true)
    clone.querySelectorAll("template").forEach((node) => node.remove())
    clone.classList.add("chats-popup__bubble")
    // The clone must LOOK like the original: same width (bubbles size to
    // content — letting the slot re-wrap them reads as a different element),
    // and the own-context class goes on the SLOT so every descendant rule
    // keyed on `.chats-message--own …` (gem CSS and host ancestor variants
    // alike) still applies inside the popup.
    clone.style.width = `${originRect.width}px`
    // Mount INVISIBLE: between insertion and the FLIP transform a frame can
    // paint, flashing the clone at its slot position before it "jumps" home
    // — the visible half of the reported jank. The original bubble stays
    // visible meanwhile, and the two swap in a single frame below.
    clone.style.visibility = "hidden"
    this.popupBubbleTarget.classList.toggle("chats-message--own", own)
    this.popupBubbleTarget.replaceChildren(clone)

    this.popupOpenFor = bubble
    this.popupVisual = visual
    this.popupTarget.hidden = false
    this.suppressNextClick = true

    // Anchor the stack to the bubble's OWN side — own messages stay pinned
    // right, others stay pinned left at their exact x. Telegram never drags
    // a message to the horizontal center; only the vertical position changes
    // (to make room for the pill above and the menu below).
    const stack = this.popupBubbleTarget.parentElement
    const viewportWidth = document.documentElement.clientWidth
    const gutter = 12
    stack.classList.toggle("chats-popup__stack--own", own)
    if (own) {
      stack.style.left = "auto"
      stack.style.right = `${Math.max(viewportWidth - originRect.right, gutter)}px`
    } else {
      stack.style.right = "auto"
      stack.style.left = `${Math.max(originRect.left, gutter)}px`
    }
    stack.style.maxWidth = `${viewportWidth - gutter * 2}px`

    const targetRect = clone.getBoundingClientRect()
    clone.style.transform =
      `translate(${originRect.left - targetRect.left}px, ${originRect.top - targetRect.top}px)`

    // One frame: clone appears exactly over the original as the original
    // hides — no gap, no double image. Next frame starts the morph.
    requestAnimationFrame(() => {
      clone.style.visibility = ""
      visual.classList.add("chats-message--lifted")
      requestAnimationFrame(() => {
        this.popupTarget.classList.add("chats-popup--open")
        clone.style.transform = ""
      })
    })

    this.popupKeydown = (event) => {
      if (event.key === "Escape") this.closePopup()
    }
    document.addEventListener("keydown", this.popupKeydown)
  }

  closePopup() {
    const bubble = this.popupOpenFor
    if (!bubble) return
    this.popupOpenFor = null

    const clone = this.popupBubbleTarget.firstElementChild
    const visual = this.popupVisual
    // Reverse FLIP against the bubble's CURRENT rect — the thread may have
    // appended/scrolled underneath while the popup was open.
    if (clone && visual) {
      const originRect = visual.getBoundingClientRect()
      const targetRect = clone.getBoundingClientRect()
      clone.style.transform =
        `translate(${originRect.left - targetRect.left}px, ${originRect.top - targetRect.top}px)`
    }
    this.popupTarget.classList.remove("chats-popup--open")
    this.suppressNextClick = false

    clearTimeout(this.popupCloseTimer)
    this.popupCloseTimer = setTimeout(() => this.teardownPopup(visual), POPUP_TRANSITION_MS)
    document.removeEventListener("keydown", this.popupKeydown)
  }

  teardownPopup(visual = this.popupVisual) {
    if (!this.hasPopupTarget) return
    this.popupTarget.hidden = true
    this.popupTarget.classList.remove("chats-popup--open")
    this.popupReactionsTarget.replaceChildren()
    this.popupBubbleTarget.replaceChildren()
    this.popupBubbleTarget.classList.remove("chats-message--own")
    this.popupMenuTarget.replaceChildren()
    const stack = this.popupBubbleTarget.parentElement
    if (stack) {
      stack.classList.remove("chats-popup__stack--own")
      stack.style.left = ""
      stack.style.right = ""
      stack.style.maxWidth = ""
    }
    visual?.classList?.remove("chats-message--lifted")
    this.popupVisual = null
  }

  popupMenuClicked(event) {
    const item = event.target.closest("[data-chats-action], form button, form input[type=submit]")
    if (!item) return

    const action = item.dataset.chatsAction
    if (action === "copy") {
      event.preventDefault()
      this.copyMessage(item)
    } else if (action === "edit") {
      event.preventDefault()
      this.beginEditFromPopup()
    } else {
      // A real form submission (reaction toggle, delete): let it fire, then
      // get out of the way — Telegram closes on selection too. The cloned
      // form's request has already started by the time we tear down.
      setTimeout(() => this.closePopup(), 60)
    }
  }

  copyMessage(item) {
    const text = this.pressedMessageBody()
    if (!text) return this.closePopup()

    this.writeClipboard(text).then((copied) => {
      if (copied && this.copiedLabelValue) {
        item.textContent = this.copiedLabelValue
        setTimeout(() => this.closePopup(), 450)
      } else {
        this.closePopup()
      }
    })
  }

  // Clipboard order matters, and it's the reverse of what you'd expect:
  // execCommand("copy") FIRST, synchronously, while we are still inside the
  // user-gesture call stack — then navigator.clipboard as the fallback.
  // Two WebKit realities force this (measured on iOS 26 WKWebView, 2026-06):
  //   * navigator.clipboard.writeText can reject in embedded WebViews (and
  //     doesn't exist at all on insecure dev origins), and
  //   * by the time its rejection handler runs (a microtask), WebKit has
  //     dropped the transient user-activation token — so a fallback
  //     execCommand inside .then()/.catch() silently copies NOTHING.
  // Running the legacy path inside the original tap frame works on iOS
  // WKWebView, Android WebView, and every desktop browser today; the async
  // API only needs to carry contexts that have removed execCommand.
  // https://developer.mozilla.org/docs/Web/API/Clipboard/writeText#security_considerations
  // https://webkit.org/blog/10855/async-clipboard-api/ (gesture requirements)
  writeClipboard(text) {
    if (this.legacyClipboard(text)) return Promise.resolve(true)
    if (navigator.clipboard?.writeText) {
      return navigator.clipboard.writeText(text).then(() => true, () => false)
    }
    return Promise.resolve(false)
  }

  legacyClipboard(text) {
    const area = document.createElement("textarea")
    area.value = text
    area.setAttribute("readonly", "")
    area.style.position = "fixed"
    area.style.opacity = "0"
    document.body.appendChild(area)
    area.focus()
    area.select()
    let copied = false
    try {
      copied = document.execCommand("copy")
    } catch {
      copied = false
    }
    area.remove()
    return copied
  }

  // The pressed message's body text, with line breaks intact. innerText
  // (not textContent) is what preserves the rendered paragraph breaks — but
  // innerText of a HIDDEN element is "", and the original bubble is exactly
  // the node the open popup hides (.chats-message--lifted). So read the
  // popup's visible CLONE first — it carries the same marked body node —
  // and only fall back to the original (e.g. mid-teardown).
  // https://developer.mozilla.org/docs/Web/API/HTMLElement/innerText
  pressedMessageBody() {
    const selector = "[data-chats-message-body], .chats-message__text"
    const source =
      (this.hasPopupBubbleTarget && this.popupBubbleTarget.querySelector(selector)) ||
      this.popupOpenFor?.querySelector(selector)
    return source?.innerText?.trim() || ""
  }

  // Edit happens in the COMPOSER (Telegram's flow): close the popup (the
  // bubble morphs back home) and hand the body off via a DOM event the
  // chats--composer controller listens for — it shows the "edit message"
  // quote cue and re-targets its form at the message's update URL.
  beginEditFromPopup() {
    const bubble = this.popupOpenFor
    if (!bubble) return
    const body = this.pressedMessageBody()
    const messageId = bubble.id.split("_").pop()

    this.closePopup()
    // `thread`: a page can hold several threads (the page's and the dock's
    // windows), each with its own composer listening on window — the
    // composer inside THIS thread is the one that edits.
    window.dispatchEvent(new CustomEvent("chats:edit-message", {
      detail: { id: messageId, body: body, thread: this.element }
    }))
  }

  // --- Chronology guard -------------------------------------------------------------

  // Broadcast appends from concurrent host jobs can land out of order.
  // ISO8601 strings compare lexicographically = chronologically; equal
  // timestamps (same-second bursts) keep arrival order (stable).
  ensureChronological(element) {
    const timestamp = element.dataset.timestamp
    if (!timestamp) return false

    const newerThan = (node) =>
      node?.classList?.contains("chats-message") && node.dataset.timestamp > timestamp

    let anchor = element.previousElementSibling
    if (!newerThan(anchor)) return false

    while (newerThan(anchor.previousElementSibling)) {
      anchor = anchor.previousElementSibling
    }
    anchor.parentElement.insertBefore(element, anchor)
    return true
  }
}

function csrfToken() {
  return document.querySelector('meta[name="csrf-token"]')?.content || ""
}
