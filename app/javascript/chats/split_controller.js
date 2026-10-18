import { Controller } from "@hotwired/stimulus"

// chats--split — the two-pane messaging page (`config.inbox_layout = :split`).
//
// chats.css lays the page out on its own, with one media query: both panes
// from 700px wide, one below. What CSS can't decide is where a row's link
// goes, and that is all this does:
//
//   * wide: the conversation frame is enabled, so a row opens its
//     conversation beside the list, in one request for the pane alone, and
//     the address bar moves to /messages/:id (the frame's
//     data-turbo-action="advance");
//   * narrow: the frame stays `disabled`, so the same link opens the
//     conversation's page, which then fills the screen. A disabled frame is
//     one Turbo never navigates, links naming it included. And no hover
//     prefetch: the link names the frame, so Turbo would ask for the pane
//     alone, and the page visit would then render that answer as the page.
//
// The server always renders the frame disabled, because a page visit is
// right at any width: it is what a click does before this connects, and
// without JavaScript. So the page's refreshes (Turbo 8 morphs, every live
// update of the list) would disable it again on a wide screen; the frame
// keeps what the screen says.
//
// When the pane opens a conversation, its row becomes the current one
// (aria-current="page", .chats-row--current) at once, exactly as the server
// renders /messages/:id, instead of when the list next refreshes.
//
// Registered as "chats--split" through the engine's importmap pin.
const WIDE = "(min-width: 700px)" // keep in step with chats.css

export default class extends Controller {
  static targets = ["frame", "list"]

  connect() {
    this.media = window.matchMedia?.(WIDE)
    this.media?.addEventListener?.("change", this.layout)
    this.layout()
  }

  disconnect() {
    this.media?.removeEventListener?.("change", this.layout)
  }

  layout = () => {
    if (this.hasFrameTarget) this.frameTarget.toggleAttribute("disabled", !this.media?.matches)
  }

  // turbo:before-morph-attribute: a refresh leaves the frame as the screen has it.
  keepEnabled(event) {
    if (event.target === this.frameTarget && event.detail?.attributeName === "disabled") event.preventDefault()
  }

  // turbo:before-prefetch: nothing names a frame that can't take it.
  prefetch(event) {
    if (!this.hasFrameTarget || !this.frameTarget.hasAttribute("disabled")) return
    if (event.target?.getAttribute?.("data-turbo-frame") === this.frameTarget.id) event.preventDefault()
  }

  // turbo:frame-load: the pane opened a conversation.
  opened(event) {
    if (!this.hasFrameTarget || event.target !== this.frameTarget || !this.hasListTarget) return
    const src = this.frameTarget.getAttribute("src")
    if (!src) return

    const open = new URL(src, document.baseURI).pathname
    this.listTarget.querySelectorAll(`a[data-turbo-frame="${this.frameTarget.id}"]`).forEach((link) => {
      const current = new URL(link.getAttribute("href"), document.baseURI).pathname === open
      if (current) {
        link.setAttribute("aria-current", "page")
      } else {
        link.removeAttribute("aria-current")
      }
      link.closest(".chats-row")?.classList.toggle("chats-row--current", current)
    })
  }
}
