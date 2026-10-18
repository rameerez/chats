import { Controller } from "@hotwired/stimulus"
import { recoverMissedBroadcasts } from "chats/recovery"

// chats--refresh-inbox — the inbox is never left showing an old list.
//
// The inbox updates through Turbo 8 page refreshes on the viewer's inbox
// stream (Chats::Broadcasts.refresh_inbox_of): the page re-requests itself
// and morphs, scroll kept. This controller wraps that stream's
// <turbo-cable-stream-source> and covers the ways a refresh can be lost:
//
//   * MISSED, because the socket was down when it was sent: chats/recovery
//     runs the same page refresh when the stream reconnects, when the page
//     comes back after 10 seconds hidden, when the network comes back, and
//     when the browser restores the page from its back/forward cache.
//   * DROPPED, because it arrived while a visit was in flight: Turbo ignores
//     a refresh while another visit is running (Session#refresh checks
//     `navigator.currentVisit`), so a message that lands while the previous
//     refresh is being fetched would be lost with a healthy socket. One
//     arriving then is run once that visit completes.
//
// A refresh never rewrites the field the viewer is typing in: the morph
// leaves the focused field's value alone. The search itself survives a
// refresh because the inbox's search form keeps the query in the URL
// (`data-turbo-action="replace"`), which is what a refresh re-requests.
//
// The catch-up IS a page refresh, on the same code path a broadcast takes:
// in Hotwire Native, Turbo hands it to the native adapter like any other.
// Registered as "chats--refresh-inbox" through the engine's importmap pin.
export default class extends Controller {
  connect() {
    this.stopRecovery = recoverMissedBroadcasts(this.element, () => this.refresh())
    document.addEventListener("turbo:visit", this.visitStarted)
    document.addEventListener("turbo:load", this.visitCompleted)
    document.addEventListener("turbo:before-stream-render", this.streamArrived)
    document.addEventListener("turbo:before-morph-attribute", this.keepWhatIsBeingTyped)
  }

  disconnect() {
    this.stopRecovery()
    document.removeEventListener("turbo:visit", this.visitStarted)
    document.removeEventListener("turbo:load", this.visitCompleted)
    document.removeEventListener("turbo:before-stream-render", this.streamArrived)
    document.removeEventListener("turbo:before-morph-attribute", this.keepWhatIsBeingTyped)
  }

  refresh() {
    window.Turbo?.session?.refresh(document.baseURI, { method: "morph", scroll: "preserve" })
  }

  // --- A refresh that lands mid-visit -------------------------------------------
  //
  // Turbo marks <html aria-busy> for as long as a visit runs.

  streamArrived = (event) => {
    if (event.target.getAttribute?.("action") !== "refresh") return
    if (document.documentElement.hasAttribute("aria-busy")) this.refreshWaiting = true
  }

  // A visit that starts after the refresh arrived fetches what it was about.
  visitStarted = () => {
    this.refreshWaiting = false
  }

  visitCompleted = () => {
    if (!this.refreshWaiting) return

    this.refreshWaiting = false
    if (this.element.isConnected) this.refresh()
  }

  // --- Typing through a refresh ---------------------------------------------------

  keepWhatIsBeingTyped = (event) => {
    if (event.detail?.attributeName === "value" && event.target === document.activeElement) event.preventDefault()
  }
}
