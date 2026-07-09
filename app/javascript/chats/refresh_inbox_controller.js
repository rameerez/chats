import { Controller } from "@hotwired/stimulus"

// chats--refresh-inbox — heals the inbox after a MISSED broadcast.
//
// The inbox updates via Turbo 8 page-refresh broadcasts
// (Chats::Broadcasts.refresh_inbox_of → broadcast_refresh_later_to). Action
// Cable has no replay: a refresh broadcast sent while this client's socket
// was down (backgrounded tab/app, network blip, laptop asleep) is gone
// forever, and the inbox silently sits at its last render until the user
// happens to navigate. This controller re-runs the SAME page refresh on the
// two moments we might have missed one — the socket reconnecting, and the
// tab becoming visible again after long enough that the socket was reaped.
//
// It deliberately reuses chats--thread's reconnect/visibility detection (the
// gem-native approach: observe the <turbo-cable-stream-source> `connected`
// attribute rather than stand up a dedicated HeartbeatChannel — the attribute
// IS the heartbeat). The difference is the recovery action: the thread does an
// HTTP `?since=` delta because it patches messages surgically, whereas the
// inbox already broadcasts whole-page refreshes, so the catch-up is just
// `Turbo.session.refresh()` — idempotent, morphing, scroll-preserving.
//
// Registered automatically under the identifier "chats--refresh-inbox" via
// the engine's importmap pin (see config/importmap.rb + Chats::Engine).
//
// Doctrine: Turbo Stream delivery is a best-effort enhancement; the page must
// be correct without it. https://turbo.hotwired.dev/handbook/streams
const REFRESH_AFTER_HIDDEN_MS = 60_000

export default class extends Controller {
  connect() {
    this.streamDropped = false
    this.hiddenAt = null
    document.addEventListener("visibilitychange", this.visibilityChanged)
    this.watchStreamSource()
  }

  disconnect() {
    document.removeEventListener("visibilitychange", this.visibilityChanged)
    this.sourceObserver?.disconnect()
  }

  visibilityChanged = () => {
    if (document.visibilityState === "visible") {
      // Hidden long enough that the socket may have been reaped → catch up
      // on whatever the missed broadcasts would have refreshed.
      if (this.hiddenAt && Date.now() - this.hiddenAt > REFRESH_AFTER_HIDDEN_MS) {
        this.refresh()
      }
      this.hiddenAt = null
    } else {
      this.hiddenAt = Date.now()
    }
  }

  // Reconnect detection without a dedicated cable channel: turbo-rails toggles
  // a `connected` attribute on <turbo-cable-stream-source> as the Action Cable
  // subscription confirms/drops, so observing it IS the heartbeat. A refresh
  // that morphs the page can momentarily strip the attribute — harmless here:
  // it only arms `streamDropped`, and the next genuine reconnect does one
  // (cheap, idempotent) catch-up refresh.
  watchStreamSource() {
    const source = this.element.querySelector("turbo-cable-stream-source")
    if (!source || typeof MutationObserver === "undefined") return

    this.sourceObserver = new MutationObserver(() => {
      const connected = source.hasAttribute("connected")
      if (connected && this.streamDropped) {
        this.streamDropped = false
        this.refresh()
      } else if (!connected) {
        this.streamDropped = true
      }
    })
    this.sourceObserver.observe(source, { attributes: true, attributeFilter: ["connected"] })
  }

  refresh() {
    if (document.visibilityState !== "visible") return
    // Don't morph the list out from under someone typing in the search box —
    // the next trigger (or their own submit) will catch it up.
    const active = document.activeElement
    if (active && active.matches("input, textarea, select")) return

    window.Turbo?.session?.refresh(document.baseURI)
  }
}
