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
// The tab's title follows the pane: Turbo leaves <head> alone when it
// promotes a frame load to a visit, so the title would stay the previous
// page's. The pane carries the page's title with it open (`data-title`,
// chats_page_title: the same the full page gives `content_for :title`).
//
// The open conversation's row stops counting it unread as soon as it is
// read (the pane's answer says the server read it, `data-read`; or its
// thread reads it on screen, `chats:read`), without waiting for the list's
// live refresh, which may be seconds away or not come at all.
//
// When the pane opens a conversation, its row becomes the current one
// (aria-current="page", .chats-row--current) at once, exactly as the server
// renders /messages/:id, instead of when the list next refreshes. And the
// focus goes where the viewer is now, as LinkedIn's messaging page does:
// into the conversation's composer, ready to reply. Entering the pane, a
// screen reader names it (a section labelled by the conversation's title),
// then the field. On a touch screen the composer would raise the keyboard
// over a conversation not read yet, so the focus goes to the pane's title
// instead (tabindex="-1"), which is read out the same; and to the title
// too when there is nothing to write in (a locked conversation).
//
// Registered as "chats--split" through the engine's importmap pin.
const WIDE = "(min-width: 700px)" // keep in step with chats.css
const TOUCH = "(pointer: coarse)"

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

  // turbo:frame-load: the pane opened a conversation. Its row is current,
  // and the viewer is taken to it.
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
    const pane = this.frameTarget.querySelector(".chats-split__pane")
    if (pane?.dataset.title) document.title = pane.dataset.title
    if (pane?.dataset.read === "true") this.markRead(pane)
    this.arrive()
  }

  // chats:read, from the pane's thread.
  threadRead(event) {
    const pane = event.target?.closest?.(".chats-split__pane")
    if (pane) this.markRead(pane)
  }

  // The conversation's row, read: no count, no bold, as the next refresh
  // will render it.
  markRead(pane) {
    if (!this.hasListTarget || !pane.dataset.path) return

    const path = new URL(pane.dataset.path, document.baseURI).pathname
    this.listTarget.querySelectorAll(`a[data-turbo-frame="${this.frameTarget.id}"]`).forEach((link) => {
      if (new URL(link.getAttribute("href"), document.baseURI).pathname !== path) return

      const row = link.closest(".chats-row")
      row?.classList.remove("chats-row--unread")
      row?.querySelector(".chats-row__bottom .chats-badge")?.remove()
    })
  }

  arrive() {
    const pane = this.frameTarget.querySelector(".chats-split__pane")
    if (!pane) return

    const touch = Boolean(window.matchMedia?.(TOUCH)?.matches)
    const composer = touch ? null : pane.querySelector(".chats-composer__input")
    const title = pane.querySelector(`[id="${pane.getAttribute("aria-labelledby")}"]`)
    ;(composer || title)?.focus({ preventScroll: true })
  }
}
