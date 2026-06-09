import { Controller } from "@hotwired/stimulus"

// chats--composer: the message box.
//
//   * autosize            grow the textarea with content (capped)
//   * Enter-to-send       desktop only ("pointer: fine") — on touch keyboards
//                         Enter means newline, like every messaging app;
//                         Shift+Enter always inserts a newline; IME
//                         composition (event.isComposing) never sends
//   * typing pings        throttled POST (~1 per 2.5s while typing) that the
//                         server fans out as the chats_typing stream action;
//                         disabled when the server didn't render a typing URL
//   * reset-on-success    listens for turbo:submit-end (wired via data-action
//                         on the form) and clears/refocuses only on success —
//                         a 422 keeps the draft intact
export default class extends Controller {
  static targets = ["input", "files", "fileCount"]
  static values = { typingUrl: String }

  connect() {
    this.lastTypedAt = 0
    this.autosize()
  }

  typed() {
    this.autosize()
    this.pingTyping()
  }

  enterSend(event) {
    if (event.shiftKey || event.isComposing) return
    if (!window.matchMedia("(pointer: fine)").matches) return

    event.preventDefault()
    if (this.empty()) return
    this.element.requestSubmit()
  }

  submitted(event) {
    if (!event.detail.success) return

    this.element.reset()
    if (this.hasFileCountTarget) this.fileCountTarget.hidden = true
    this.autosize()
    if (this.hasInputTarget) this.inputTarget.focus()
  }

  filesChanged() {
    if (!this.hasFilesTarget || !this.hasFileCountTarget) return
    const count = this.filesTarget.files.length
    this.fileCountTarget.textContent = count > 0 ? String(count) : ""
    this.fileCountTarget.hidden = count === 0
  }

  // --- Internals ---------------------------------------------------------------

  autosize() {
    if (!this.hasInputTarget) return
    const input = this.inputTarget
    input.style.height = "auto"
    input.style.height = `${Math.min(input.scrollHeight, 160)}px`
  }

  pingTyping() {
    if (!this.typingUrlValue || this.empty()) return

    const now = Date.now()
    if (now - this.lastTypedAt < 2500) return
    this.lastTypedAt = now

    fetch(this.typingUrlValue, {
      method: "POST",
      headers: { "X-CSRF-Token": csrfToken(), Accept: "application/json" }
    }).catch(() => {})
  }

  empty() {
    const hasText = this.hasInputTarget && this.inputTarget.value.trim().length > 0
    const hasFiles = this.hasFilesTarget && this.filesTarget.files.length > 0
    return !hasText && !hasFiles
  }
}

function csrfToken() {
  return document.querySelector('meta[name="csrf-token"]')?.content || ""
}
