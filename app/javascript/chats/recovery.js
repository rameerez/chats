// chats/recovery — every live surface catches up on the broadcasts it missed.
//
// Action Cable has no replay. A broadcast sent while this page's socket is
// down (a laptop asleep, a phone in a pocket, a backgrounded Hotwire Native
// WebView, an elevator) never arrives, and nothing tells the page it missed
// anything. Turbo's own doctrine is that stream delivery is best effort and a
// page must be correct without it (https://turbo.hotwired.dev/handbook/streams).
// So every surface that lives on a stream (the inbox, a thread, the unread
// badge, the dock) asks for what it missed at the moments it may have missed
// something:
//
//   1. its stream RECONNECTS: its <turbo-cable-stream-source> confirms the
//      subscription again;
//   2. the page comes BACK after being hidden for 10 seconds or more (an
//      app foregrounded, a tab returned to);
//   3. the network comes back ONLINE: Action Cable is asked to check its
//      socket now instead of after its backoff (a dead one reconnects, which
//      is trigger 1), and the surface catches up anyway: after a short
//      outage the socket can still look open while what was sent during it
//      is gone;
//   4. the browser RESTORES the page from its back/forward cache.
//
// Never otherwise. While the socket is healthy and the page is on screen
// nothing is fetched: there is no polling.
//
//   connect()    { this.stopRecovery = recoverMissedBroadcasts(this.element, () => this.catchUp()) }
//   disconnect() { this.stopRecovery() }
//
// Triggers that come together (an app foregrounding fires 2 and then 1) make
// one catch-up, and two catch-ups are at least five seconds apart, so a
// flapping connection can't turn into a fetch loop. A page that is hidden
// never fetches: what it should catch up on waits until it is seen.
//
// How a reconnect is seen. turbo-rails sets a `connected` attribute on the
// stream source each time Action Cable confirms its subscription, and removes
// it when the socket closes. Every confirmation after the first is a
// reconnect, whether or not the close was ever reported: when Action Cable
// reopens a socket that went quiet (the half-open TCP of a phone that slept),
// it swaps the old socket's handlers out before that socket's close event can
// arrive, so subscribers never hear "disconnected", only "connected" again —
// and its `reconnected: true` detail goes to the first subscription confirmed
// and nobody else (actioncable/app/javascript/action_cable/connection.js).
// Watching the stream's OWN confirmations, instead of a separate heartbeat
// subscription, also means the catch-up fetch starts only once this stream
// is live again, so nothing can fall between the two.
//
// A page Turbo restores from its snapshot cache (a back navigation, a
// Hotwire Native stack pop) is as old as the moment it was left, and no
// request is made for it. Its stream sources are marked as they go into the
// cache (`chats-cached`, set on `turbo:before-cache`), so when one comes
// back its first confirmation counts as a reconnect: a restored page catches
// up as soon as it is live. A page Turbo fetches fresh carries no mark and
// fetches nothing more.

const SOURCE = "turbo-cable-stream-source"
const CACHED = "chats-cached"
const AWAY_FOR_MS = 10_000
const TOGETHER_MS = 250
const SPACED_BY_MS = 5_000

// Watch +element+'s stream sources (all of them, or those matching
// `sources:`, a selector) and the page, and call +catchUp+ whenever a
// broadcast may have been missed. Returns the function that stops watching.
export function recoverMissedBroadcasts(element, catchUp, { sources = SOURCE } = {}) {
  const recovery = new Recovery(element, catchUp, sources)
  recovery.start()
  return () => recovery.stop()
}

// GET +url+ as a Turbo Stream and render it. The same request made twice at
// once is made once. Anything but a Turbo Stream (a sign-in page after the
// session expired, an error page) is ignored: the next catch-up tries again.
const requests = new Map()

export function renderStreamFrom(url) {
  if (!requests.has(url)) {
    const request = fetch(url, { headers: { Accept: "text/vnd.turbo-stream.html" }, credentials: "same-origin" })
      .then((response) => (isTurboStream(response) ? response.text() : ""))
      .then((html) => { if (html) window.Turbo?.renderStreamMessage(html) })
      .catch(() => {})
      .finally(() => requests.delete(url))
    requests.set(url, request)
  }
  return requests.get(url)
}

function isTurboStream(response) {
  return response.ok && (response.headers.get("Content-Type") || "").startsWith("text/vnd.turbo-stream.html")
}

// Two page-wide listeners, installed once:
//
//   * A page refresh morphs every element to the server's HTML, and the
//     server never renders `connected`: a morph would strip it from a stream
//     source whose subscription is still live, and the attribute would stop
//     telling the truth until the next reconnect. Keep it.
//   * Mark the stream sources of a page going into Turbo's snapshot cache.
//     Not a permanent element's: Turbo carries the live one along instead of
//     restoring it, and it is never stale.
let watchingPage = false

function watchPage() {
  if (watchingPage) return
  watchingPage = true

  document.addEventListener("turbo:before-morph-attribute", (event) => {
    if (event.target.localName === SOURCE && event.detail?.attributeName === "connected") event.preventDefault()
  })
  document.addEventListener("turbo:before-cache", () => {
    document.querySelectorAll(SOURCE).forEach((source) => {
      if (!source.closest("[data-turbo-permanent]")) source.setAttribute(CACHED, "")
    })
  })
}

class Recovery {
  constructor(element, catchUp, sources) {
    this.element = element
    this.catchUp = catchUp
    this.selector = sources
    this.confirmed = new WeakSet()
    this.lastCaughtUpAt = -Infinity
  }

  start() {
    watchPage()
    this.hiddenAt = document.visibilityState === "visible" ? null : Date.now()

    this.observer = new MutationObserver((records) => this.sourcesChanged(records))
    this.sources.forEach((source) => {
      if (source.hasAttribute(CACHED)) {
        source.removeAttribute(CACHED)
        this.confirmed.add(source)
      }
      this.observer.observe(source, { attributes: true, attributeFilter: ["connected"] })
    })

    document.addEventListener("visibilitychange", this.visibilityChanged)
    window.addEventListener("online", this.online)
    window.addEventListener("pageshow", this.pageShown)
  }

  stop() {
    this.observer?.disconnect()
    document.removeEventListener("visibilitychange", this.visibilityChanged)
    window.removeEventListener("online", this.online)
    window.removeEventListener("pageshow", this.pageShown)
    clearTimeout(this.timer)
    this.timer = null
  }

  get sources() {
    return Array.from(this.element.querySelectorAll(this.selector))
  }

  // --- Triggers ---------------------------------------------------------------

  sourcesChanged(records) {
    records.forEach(({ target: source }) => {
      if (!source.hasAttribute("connected")) return
      if (this.confirmed.has(source)) this.request()
      this.confirmed.add(source)
    })
  }

  visibilityChanged = () => {
    if (document.visibilityState !== "visible") {
      this.hiddenAt ??= Date.now()
      return
    }

    const away = this.hiddenAt !== null && Date.now() - this.hiddenAt >= AWAY_FOR_MS
    this.hiddenAt = null
    if (away || this.pending) this.request()
  }

  online = () => {
    this.checkSocket()
    this.request()
  }

  pageShown = (event) => {
    if (!event.persisted) return

    this.checkSocket()
    this.request()
  }

  // Action Cable checks its socket when the page becomes visible
  // (ConnectionMonitor#visibilityDidChange): stale or closed, it reopens it
  // at once instead of waiting out its reconnect backoff. Ask for the same
  // check now, when there is a monitor to ask.
  checkSocket() {
    const monitor = this.sources[0]?.subscription?.consumer?.connection?.monitor
    if (typeof monitor?.visibilityDidChange === "function") monitor.visibilityDidChange()
  }

  // --- Catching up ----------------------------------------------------------------

  request() {
    this.pending = true
    if (this.timer) return

    const wait = Math.max(TOGETHER_MS, this.lastCaughtUpAt + SPACED_BY_MS - Date.now())
    this.timer = setTimeout(() => this.flush(), wait)
  }

  flush() {
    this.timer = null
    // Hidden (it waits to be seen), or a Turbo preview the real page is
    // about to replace.
    if (document.visibilityState !== "visible") return
    if (document.documentElement.hasAttribute("data-turbo-preview")) return

    this.pending = false
    this.lastCaughtUpAt = Date.now()
    this.catchUp()
  }
}
