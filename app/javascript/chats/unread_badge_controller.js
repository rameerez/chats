import { Controller } from "@hotwired/stimulus"
import { recoverMissedBroadcasts, renderStreamFrom } from "chats/recovery"

// chats--unread-badge — the unread badge (`chats_unread_badge`) never sits
// on an old count.
//
// The badge updates live on the viewer's badge stream. When that stream may
// have missed an update (chats/recovery: a reconnect, a return after 10
// seconds hidden, the network back, a restored page), this asks GET /badge
// for every unread badge on the page, the dock's included, and renders
// them. Nothing is fetched while the stream is healthy.
//
// Registered as "chats--unread-badge" through the engine's importmap pin.
export default class extends Controller {
  static values = { url: String }

  connect() {
    this.stopRecovery = recoverMissedBroadcasts(this.element, () => renderStreamFrom(this.urlValue))
  }

  disconnect() {
    this.stopRecovery()
  }
}
