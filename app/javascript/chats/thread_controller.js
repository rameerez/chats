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
//   * "Seen" indicator          derive, client-side, the newest OWN message
//                               every other participant has read (from the
//                               broadcast read-state payload) and float the
//                               label under it
//   * typing indicator          a Turbo Stream CUSTOM ACTION (no Action Cable
//                               channel of its own) — see registration below
//
// Registered automatically by stimulus-rails' eagerLoadControllersFrom
// because the engine pins this file under controllers/chats/ (identifier:
// "chats--thread"). See Chats::Engine's importmap initializer.
export default class extends Controller {
  static targets = ["scroller", "message", "typing", "readState"]
  static values = {
    me: String,
    readUrl: String,
    seenLabel: String,
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
      this.renderSeen()
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
    this.renderSeen()
  }

  classify(element) {
    if (element.dataset.senderKey && element.dataset.senderKey === this.meValue) {
      element.classList.add("chats-message--own")
    }
  }

  // --- Read state ("Seen") -----------------------------------------------------

  readStateTargetConnected() {
    if (!this.booting) this.renderSeen()
  }

  renderSeen() {
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
    if (others.length === 0 || others.some((readAt) => !readAt)) {
      this.detachSeen()
      return
    }
    const horizon = others.reduce((min, readAt) => (readAt < min ? readAt : min))

    const lastSeenOwn = this.messageTargets.findLast(
      (el) => el.dataset.senderKey === this.meValue && el.dataset.timestamp <= horizon
    )
    if (lastSeenOwn) {
      this.seenElement.remove()
      lastSeenOwn.insertAdjacentElement("afterend", this.seenElement)
    } else {
      this.detachSeen()
    }
  }

  get seenElement() {
    if (!this._seenElement) {
      this._seenElement = document.createElement("div")
      this._seenElement.className = "chats-seen"
      this._seenElement.textContent = this.seenLabelValue
    }
    return this._seenElement
  }

  detachSeen() {
    this._seenElement?.remove()
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
