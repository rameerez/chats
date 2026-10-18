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

// GET +url+ as a Turbo Stream and render it, as long as `when` says it is
// still wanted (its page wasn't rendered again meanwhile). Asked when the
// answer arrives, and again by every stream of it at the moment Turbo is
// about to apply it, a repaint later: a page visit or a frame reload in
// that gap gives the old streams a new page to land on, and they are
// dropped instead. Resolves once Turbo has applied all of it, to true, or
// to false when nothing was applied — never before: a caller that reads
// the page afterwards reads what the answer did. The same request made
// twice at once is made once; after APPLY_WITHIN_MS a request whose answer
// Turbo hasn't applied yet no longer stands in for a new one. Anything but
// a Turbo Stream (a sign-in page after the session expired, an error page)
// is ignored: the next catch-up tries again.
const requests = new Map()
const APPLY_WITHIN_MS = 2_000

export function renderStreamFrom(url, { when = () => true } = {}) {
  if (requests.has(url)) return requests.get(url)

  const release = () => { if (requests.get(url) === request) requests.delete(url) }
  const request = fetch(url, { headers: { Accept: "text/vnd.turbo-stream.html" }, credentials: "same-origin" })
    .then((response) => (isTurboStream(response) ? response.text() : ""))
    .then((html) => {
      if (!html || !when()) return false

      setTimeout(release, APPLY_WITHIN_MS)
      return renderWhile(html, when)
    })
    .catch(() => false)
    .finally(release)
  requests.set(url, request)
  return request
}

// Turbo announces each stream it is given (turbo:before-stream-render,
// synchronously, as the stream joins the page) and lets the listener wrap
// how it renders: ours renders it only if `when` still holds when Turbo
// gets to it.
function renderWhile(html, when) {
  if (!window.Turbo?.renderStreamMessage) return Promise.resolve(false)

  let applied = false
  const guard = (event) => {
    const render = event.detail?.render
    if (typeof render !== "function") return

    event.detail.render = async (stream) => {
      if (!when()) return
      applied = true
      await render(stream)
    }
  }

  const waiting = new Set(pendingStreams())
  document.addEventListener("turbo:before-stream-render", guard)
  try {
    window.Turbo.renderStreamMessage(html)
  } finally {
    document.removeEventListener("turbo:before-stream-render", guard)
  }
  const ours = pendingStreams().filter((stream) => !waiting.has(stream))

  return removed(ours).then(() => applied || !ours.length)
}

// Each stream removes itself from <html> once Turbo has performed it (or
// skipped it).
function removed(streams) {
  return new Promise((resolve) => {
    const gone = () => streams.every((stream) => !stream.isConnected)
    if (gone()) return resolve()

    const observer = new MutationObserver(() => {
      if (!gone()) return
      observer.disconnect()
      resolve()
    })
    observer.observe(document.documentElement, { childList: true })
  })
}

function pendingStreams() {
  return Array.from(document.documentElement.querySelectorAll?.(":scope > turbo-stream") || [])
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
