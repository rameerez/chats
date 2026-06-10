import { Controller } from "@hotwired/stimulus"

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
//                               arrive while the tab is visible — that POST
//                               advances our read horizon and broadcasts fresh
//                               read-state to everyone
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
    "attachmentDialog",
    "attachmentImage",
    "attachmentCaption"
  ]
  static values = {
    me: String,
    readUrl: String,
    sentLabel: String,
    seenLabel: String,
    todayLabel: String,
    yesterdayLabel: String,
    daySeparatorClass: { type: String, default: "chats-day-separator" },
    typingSuffix: String,
    group: Boolean
  }

  connect() {
    this.registerTypingStreamAction()

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
    })

    if (this.hasTypingTarget) {
      this.typingTarget.addEventListener("chats:typing", this.showTyping)
    }
    document.addEventListener("visibilitychange", this.visibilityChanged)
  }

  disconnect() {
    if (this.hasTypingTarget) {
      this.typingTarget.removeEventListener("chats:typing", this.showTyping)
    }
    document.removeEventListener("visibilitychange", this.visibilityChanged)
    clearTimeout(this.readTimer)
    clearTimeout(this.typingTimer)
    cancelAnimationFrame(this.daySeparatorFrame)
    cancelAnimationFrame(this.messageGroupFrame)
  }

  // --- Bubbles ---------------------------------------------------------------

  messageTargetConnected(element) {
    this.classify(element)
    if (this.booting) return

    // A new bubble after initial render: keep the viewport glued to the
    // bottom for own messages and for foreign ones when already down there.
    const own = element.dataset.senderKey === this.meValue
    if (own || this.nearBottom()) this.scrollToBottom()
    if (!own) this.queueRead()
    this.renderReceipts()
    this.scheduleDaySeparators()
    this.scheduleMessageGroups()
  }

  classify(element) {
    const own = element.dataset.senderKey && element.dataset.senderKey === this.meValue
    element.classList.toggle("chats-message--own", own)

    const receipt = element.querySelector("[data-chats-message-receipt]")
    if (receipt && !own) {
      receipt.hidden = true
      receipt.textContent = ""
      receipt.removeAttribute("aria-label")
      delete receipt.dataset.state
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
    receipt.setAttribute("aria-label", seen ? this.seenLabelValue : this.sentLabelValue)
    receipt.dataset.state = seen ? "seen" : "sent"
    receipt.hidden = false
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
    if (!this.hasAttachmentDialogTarget || !this.hasAttachmentImageTarget) return

    event.preventDefault()
    const link = event.currentTarget
    const name = link.dataset.attachmentName || ""

    this.attachmentImageTarget.src = link.href
    this.attachmentImageTarget.alt = name
    if (this.hasAttachmentCaptionTarget) this.attachmentCaptionTarget.textContent = name
    if (!this.attachmentDialogTarget.open) this.attachmentDialogTarget.showModal()
  }

  closeAttachment() {
    if (this.hasAttachmentDialogTarget && this.attachmentDialogTarget.open) this.attachmentDialogTarget.close()
  }

  closeAttachmentFromBackdrop(event) {
    if (event.target === event.currentTarget) this.closeAttachment()
  }

  resetAttachment() {
    if (this.hasAttachmentImageTarget) {
      this.attachmentImageTarget.removeAttribute("src")
      this.attachmentImageTarget.alt = ""
    }
    if (this.hasAttachmentCaptionTarget) this.attachmentCaptionTarget.textContent = ""
  }

  // --- Mark-as-read ------------------------------------------------------------

  queueRead() {
    if (document.visibilityState !== "visible") {
      this.pendingRead = true
      return
    }
    clearTimeout(this.readTimer)
    this.readTimer = setTimeout(() => this.postRead(), 700)
  }

  visibilityChanged = () => {
    if (document.visibilityState === "visible" && this.pendingRead) {
      this.pendingRead = false
      this.queueRead()
    }
  }

  postRead() {
    if (!this.readUrlValue) return
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
    this.typingTarget.textContent = `${name} ${this.typingSuffixValue}`
    this.typingTarget.hidden = false
    if (wasHidden && this.nearBottom()) this.scrollToBottom()

    clearTimeout(this.typingTimer)
    this.typingTimer = setTimeout(() => {
      this.typingTarget.hidden = true
    }, 4000)
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
}

function csrfToken() {
  return document.querySelector('meta[name="csrf-token"]')?.content || ""
}
