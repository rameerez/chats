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
// still wanted (its page wasn't rendered again meanwhile): asked when the
// answer arrives, and again by each of its streams at the moment Turbo
// applies it, a repaint later — a page visit or a frame reload in that gap
// would otherwise hand the old streams the new page.
//
// Resolves once Turbo has applied all of it, to true, or to false when
// nothing was (unwanted, cancelled, failed) — never before, however late
// Turbo gets to it: a caller that reads the page afterwards reads what the
// answer did. Bounded everywhere a request can stall:
//   * a request that hasn't answered within REQUEST_WITHIN_MS is aborted
//     (a fetch can hang across a network interruption);
//   * the same request made twice at once is made once, but an answer
//     Turbo hasn't applied within APPLY_WITHIN_MS no longer stands in for a
//     new one;
//   * one unapplied answer per `key` (the URL, or what the caller names —
//     the thread names itself): a newer answer for it cancels the older
//     one's leftover streams, and so does cancelStreamsFor(key), which the
//     thread calls as it disconnects.
// Anything but a Turbo Stream (a sign-in page after the session expired, an
// error page) is ignored: the next catch-up tries again.
const requests = new Map()
const answers = new Map() // key → the answer still being applied
const REQUEST_WITHIN_MS = 15_000
const APPLY_WITHIN_MS = 2_000

export function renderStreamFrom(url, { when = () => true, key = url, retry = null } = {}) {
  watchPageRenders()
  if (requests.has(url)) return requests.get(url)

  const abort = new AbortController()
  const hung = setTimeout(() => abort.abort(), REQUEST_WITHIN_MS)
  const release = () => { if (requests.get(url) === request) requests.delete(url) }
  const request = fetch(url, {
    headers: { Accept: "text/vnd.turbo-stream.html" },
    credentials: "same-origin",
    signal: abort.signal
  })
    .then((response) => (isTurboStream(response) ? response.text() : ""))
    .then(async (html) => {
      clearTimeout(hung)
      if (!html || !(await stillWanted(when, retry))) return false

      setTimeout(release, APPLY_WITHIN_MS)
      return apply(html, when, key, retry)
    })
    .catch(() => false)
    .finally(() => {
      clearTimeout(hung)
      release()
    })
  requests.set(url, request)
  return request
}

// Drops what is left of +key+'s answer: streams Turbo hasn't applied yet
// never will be.
export function cancelStreamsFor(key) {
  answers.get(key)?.cancel({ unwanted: true })
}

// --- Page renders ------------------------------------------------------------
//
// A Turbo visit carries a permanent element (the dock, its windows, their
// threads) to the next page by taking it off the page and putting it back
// once the new body is in. That is usually one task, but a host may render
// asynchronously (a `turbo:before-render` listener that animates, or uses a
// view transition), and the element is then off the page for as long as
// that takes. So "off the page" means "gone" only once page rendering is
// over: from each `turbo:before-render` to its `turbo:render`, counted one
// by one (a second render may start before the first ends), nothing is
// decided, and afterRendering() resolves a task after the last one ends.
//
// A render that hasn't ended after RENDER_WITHIN_MS stops holding things
// up. What is given up while it is still out (an answer, streams waiting)
// may belong to a window it will yet bring back, so it is remembered with
// its way to catch up again (`retry:`), and asked again when that render,
// late, does end: a window that is back and still wanted catches up anew.
const RENDER_WITHIN_MS = 10_000
const inFlight = [] // renders between turbo:before-render and their turbo:render, oldest first
let overdue = 0 // renders past RENDER_WITHIN_MS that haven't ended
let idle = null // { finished, resolve } while any render is in flight
const givenUp = [] // { when, retry } dropped while an overdue render was out
let watchingRenders = false

function watchPageRenders() {
  if (watchingRenders) return
  watchingRenders = true

  document.addEventListener("turbo:before-render", () => {
    if (!inFlight.length) {
      let resolve
      idle = { finished: new Promise((done) => { resolve = done }) }
      idle.resolve = resolve
    }
    const render = {}
    render.timer = setTimeout(() => {
      inFlight.splice(inFlight.indexOf(render), 1)
      overdue++
      settleIfIdle()
    }, RENDER_WITHIN_MS)
    inFlight.push(render)
  })

  document.addEventListener("turbo:render", () => {
    const render = inFlight.shift()
    if (render) {
      clearTimeout(render.timer)
    } else if (overdue) {
      overdue--
    }
    settleIfIdle()
    if (givenUp.length) afterRendering().then(askAgain)
  })
}

function settleIfIdle() {
  if (inFlight.length || !idle) return

  const { resolve } = idle
  idle = null
  setTimeout(resolve, 0)
}

// Resolves once no page render is in progress, a task after the last one
// (a render that starts within that task is waited for too).
export async function afterRendering() {
  watchPageRenders()
  do {
    await (idle ? idle.finished : new Promise((resolve) => setTimeout(resolve, 0)))
  } while (idle)
}

// Whether +when+ holds — or, if it doesn't while a page is rendering, once
// the render is over. Given up while an overdue render is out: remembered.
async function stillWanted(when, retry) {
  if (when()) return true
  if (idle) {
    await afterRendering()
    if (when()) return true
  }
  giveUp(when, retry)
  return false
}

function giveUp(when, retry) {
  if (overdue && retry) givenUp.push({ when, retry })
}

function askAgain() {
  for (const entry of givenUp.splice(0)) {
    if (entry.when()) {
      entry.retry()
    } else if (overdue) {
      givenUp.push(entry) // a render still out may bring it back
    }
  }
}

// Every stream of an answer carries its mark (data-chats-answer), so the
// page-wide guard below wraps those and no others: a host's own stream,
// rendered at the same moment, is none of its business.
let answerCount = 0

function apply(html, when, key, retry) {
  if (!window.Turbo?.renderStreamMessage) return Promise.resolve(false)
  guardStreams()
  cancelStreamsFor(key)

  const mark = `${Date.now().toString(36)}-${++answerCount}`
  return new Promise((resolve) => {
    const answer = {
      when,
      retry,
      applied: false,
      cancelled: false,
      settle(result) {
        this.observer?.disconnect()
        if (answers.get(key) === this) answers.delete(key)
        marked.delete(mark)
        resolve(result)
      },
      cancel({ unwanted = false } = {}) {
        this.cancelled = true
        streamsMarked(mark).forEach((stream) => stream.remove())
        if (unwanted) giveUp(when, retry)
        this.settle(false)
      }
    }
    answers.set(key, answer)
    marked.set(mark, answer)

    window.Turbo.renderStreamMessage(html.replace(/<turbo-stream\b/g, `<turbo-stream data-chats-answer="${mark}"`))
    const waited = streamsMarked(mark).length > 0 // an answer with no stream has nothing left to apply

    // Each stream removes itself from <html> once Turbo has performed it
    // (or skipped it). A page re-rendered meanwhile cancels the rest — asked
    // a task later, when a permanent element Turbo is carrying across a
    // visit is back on the page. (A re-render inside <body>, which this
    // doesn't see, is the caller's to cancel: the thread does as it goes.)
    const check = () => {
      if (answer.cancelled) return
      if (!streamsMarked(mark).length) return answer.settle(answer.applied || !waited)
      afterRendering().then(() => { if (!answer.cancelled && !when()) answer.cancel({ unwanted: true }) })
    }
    answer.observer = new MutationObserver(check)
    answer.observer.observe(document.documentElement, { childList: true })
    check()
  })
}

const marked = new Map() // mark → its answer
let guarding = false

function guardStreams() {
  if (guarding) return
  guarding = true

  document.addEventListener("turbo:before-stream-render", (event) => {
    const answer = marked.get(event.target?.getAttribute?.("data-chats-answer"))
    const render = event.detail?.render
    if (!answer || typeof render !== "function") return

    event.detail.render = async (stream) => {
      if (answer.cancelled || !(await stillWanted(answer.when, answer.retry)) || answer.cancelled) return
      answer.applied = true
      await render(stream)
    }
  })
}

function streamsMarked(mark) {
  return Array.from(document.documentElement.querySelectorAll?.(`:scope > turbo-stream[data-chats-answer="${mark}"]`) || [])
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
    watchPageRenders()
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
