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
//
// `stale:` says the element is known to be behind (a catch-up of its was
// given up: its page rendered it away, the request failed, Turbo never
// applied the answer). While it says so, the element also catches up when
// it connects, on its stream's first confirmation, and after every page
// render (`turbo:render`, `turbo:load`) — through the same coalescing and
// 5-second spacing as every other trigger, which also survives the element
// being carried from page to page.
export function recoverMissedBroadcasts(element, catchUp, { sources = SOURCE, stale = () => false } = {}) {
  const recovery = new Recovery(element, catchUp, sources, stale)
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
//   * the same request asked twice in the same instant is made once; asked
//     again while it is on its way, it is made once more as soon as the
//     first has its answer from the network (once for all who asked
//     meanwhile), so every caller gets an answer built after it asked,
//     within REQUEST_WITHIN_MS of the first; and an answer Turbo hasn't
//     applied within APPLY_WITHIN_MS no longer stands in for a new one;
//   * one unapplied answer per `key` (the URL, or what the caller names —
//     the thread names itself): a newer answer for it cancels the older
//     one's leftover streams, and so does cancelStreamsFor(key), which the
//     thread calls as it disconnects. "Newer" is the caller's `order` (the
//     thread numbers its catch-ups) when it gives one, else arrival: an
//     older answer arriving after a newer one is waiting is dropped instead;
//   * `applying` is called once, as the first stream of the answer is about
//     to be applied, so a caller can tell answers older than it to stop
//     (the thread's `when` turns false for them).
// Anything but a Turbo Stream (a sign-in page after the session expired, an
// error page) is ignored: the next catch-up tries again.
const requests = new Map()
const answers = new Map() // key → the answer still being applied
const REQUEST_WITHIN_MS = 15_000
const APPLY_WITHIN_MS = 2_000

export function renderStreamFrom(url, { when = () => true, key = url, order = 0, applying = () => {} } = {}) {
  watchPageRenders()

  let resolve
  const caller = { when, key, order, applying, answered: new Promise((done) => { resolve = done }) }
  caller.resolve = resolve

  const inFlight = requests.get(url)
  if (inFlight?.sameInstant) {
    // Asked in the same instant: the same answer will do.
    inFlight.callers.push(caller)
  } else if (inFlight) {
    // Asked once it was on its way: its answer is a snapshot from before
    // this was asked, and may miss what this wants. One more request, as
    // soon as that one has its answer from the network (applied or not),
    // for every caller that came meanwhile.
    if (!inFlight.queued) {
      inFlight.queued = []
      inFlight.answered.then(() => send(url, inFlight.queued))
    }
    inFlight.queued.push(caller)
  } else {
    send(url, [caller])
  }
  return caller.answered
}

// One request for +callers+ (who asked for the same URL in the same
// instant, or while the previous one was on its way). Each keeps its own
// `when`: the answer is applied if any of them still wants it, through the
// options of those who do, and each resolves to its own outcome.
function send(url, callers) {
  const abort = new AbortController()
  const hung = setTimeout(() => abort.abort(), REQUEST_WITHIN_MS)
  let networkDone
  const entry = { callers, sameInstant: true, answered: new Promise((done) => { networkDone = done }) }
  queueMicrotask(() => { entry.sameInstant = false })
  const release = () => { if (requests.get(url) === entry) requests.delete(url) }
  requests.set(url, entry)

  fetch(url, { headers: { Accept: "text/vnd.turbo-stream.html" }, credentials: "same-origin", signal: abort.signal })
    .then((response) => (isTurboStream(response) ? response.text() : ""))
    .catch(() => "")
    .then(async (html) => {
      clearTimeout(hung)
      networkDone()
      entry.sameInstant = false

      const wanted = []
      for (const caller of entry.callers) {
        if (html && await stillWanted(caller.when)) wanted.push(caller)
        else caller.resolve(false)
      }
      if (!wanted.length) return

      setTimeout(release, APPLY_WITHIN_MS)
      const newest = wanted.reduce((a, b) => (b.order > a.order ? b : a))
      const applied = await apply(html, () => wanted.some((caller) => caller.when()), newest.key, newest.order,
                                  () => wanted.forEach((caller) => caller.applying()))
      wanted.forEach((caller) => caller.resolve(applied && caller.when()))
    })
    .catch(() => entry.callers.forEach((caller) => caller.resolve(false)))
    .finally(() => {
      clearTimeout(hung)
      release()
    })
}

// Drops what is left of +key+'s answer: streams Turbo hasn't applied yet
// never will be.
export function cancelStreamsFor(key) {
  answers.get(key)?.cancel()
}

// --- Page renders ------------------------------------------------------------
//
// A Turbo visit carries a permanent element (the dock, its windows, their
// threads) to the next page by taking it off the page and putting it back
// once the new body is in. That is usually one task, but a host may render
// asynchronously (a `turbo:before-render` listener that animates, or uses a
// view transition), and the element is then off the page for as long as
// that takes. So "off the page" means "gone" only once page rendering is
// over, and afterRendering() resolves a task after the last render ends.
//
// Pairing. Turbo's events carry no identity, so each `turbo:render` ends
// the OLDEST render still on record: first in, first out. Turbo's own page
// renders never overlap (a visit waits for the previous render), so this is
// exact for them; a host whose own renders could end out of order is held
// to the same rule, with the bounds below as the safety net.
//
// Bounds. A render that hasn't ended after RENDER_WITHIN_MS stops holding
// things up, but stays on record, in its place, until its own end arrives
// (so the next `turbo:render` is still paired with it), or until
// FORGET_AFTER_MS, when it is let go for good: render records are bounded
// memory. Nothing about a stale window is kept here: what a render made a
// window give up is marked on the window itself (the thread's
// `data-chats-stale`, which travels with the permanent dock), and that
// window asks again whenever it is back — see `stale:` below.
const RENDER_WITHIN_MS = 10_000
const FORGET_AFTER_MS = 60_000
const renders = [] // oldest first: { overdue, bound, forget }
let idle = null // { finished, resolve } while a render holds things up
let watchingRenders = false

const holding = () => renders.some((render) => !render.overdue)

function watchPageRenders() {
  if (watchingRenders) return
  watchingRenders = true

  document.addEventListener("turbo:before-render", () => {
    if (!idle) {
      let resolve
      idle = { finished: new Promise((done) => { resolve = done }) }
      idle.resolve = resolve
    }
    const render = { overdue: false }
    render.bound = setTimeout(() => {
      render.overdue = true
      settleIfIdle()
    }, RENDER_WITHIN_MS)
    render.forget = setTimeout(() => {
      const index = renders.indexOf(render)
      if (index >= 0) renders.splice(index, 1)
      settleIfIdle()
    }, FORGET_AFTER_MS)
    renders.push(render)
  })

  document.addEventListener("turbo:render", () => {
    const render = renders.shift()
    if (!render) return

    clearTimeout(render.bound)
    clearTimeout(render.forget)
    settleIfIdle()
  })
}

function settleIfIdle() {
  if (holding() || !idle) return

  const { resolve } = idle
  idle = null
  setTimeout(resolve, 0)
}

// Resolves once no page render is holding things up, a task after the last
// one ends (a render that starts within that task is waited for too).
export async function afterRendering() {
  watchPageRenders()
  do {
    await (idle ? idle.finished : new Promise((resolve) => setTimeout(resolve, 0)))
  } while (idle)
}

// Whether +when+ holds — or, if it doesn't while a page is rendering, once
// the render is over.
async function stillWanted(when) {
  if (when()) return true
  if (!idle) return false
  await afterRendering()
  return when()
}

// Every stream of an answer carries its mark (data-chats-answer), so the
// page-wide guard below wraps those and no others: a host's own stream,
// rendered at the same moment, is none of its business.
let answerCount = 0

function apply(html, when, key, order, applying) {
  if (!window.Turbo?.renderStreamMessage) return Promise.resolve(false)
  guardStreams()
  if ((answers.get(key)?.order ?? -Infinity) > order) return Promise.resolve(false) // a newer one is waiting
  cancelStreamsFor(key)

  const mark = `${Date.now().toString(36)}-${++answerCount}`
  return new Promise((resolve) => {
    const answer = {
      order,
      applying,
      when,
      applied: false,
      cancelled: false,
      settle(result) {
        this.observer?.disconnect()
        if (answers.get(key) === this) answers.delete(key)
        marked.delete(mark)
        resolve(result)
      },
      cancel() {
        this.cancelled = true
        streamsMarked(mark).forEach((stream) => stream.remove())
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
      afterRendering().then(() => { if (!answer.cancelled && !when()) answer.cancel() })
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
      if (answer.cancelled || !(await stillWanted(answer.when)) || answer.cancelled) return
      if (!answer.applied) answer.applying()
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

const lastCaughtUp = new WeakMap() // element → when it last caught up

class Recovery {
  constructor(element, catchUp, sources, stale) {
    this.element = element
    this.catchUp = catchUp
    this.selector = sources
    this.stale = stale
    this.confirmed = new WeakSet()
  }

  get lastCaughtUpAt() {
    return lastCaughtUp.get(this.element) ?? -Infinity
  }

  set lastCaughtUpAt(at) {
    lastCaughtUp.set(this.element, at)
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
    document.addEventListener("turbo:render", this.pageRendered)
    document.addEventListener("turbo:load", this.pageRendered)
    window.addEventListener("online", this.online)
    window.addEventListener("pageshow", this.pageShown)
    if (this.stale()) this.request()
  }

  stop() {
    this.observer?.disconnect()
    document.removeEventListener("visibilitychange", this.visibilityChanged)
    document.removeEventListener("turbo:render", this.pageRendered)
    document.removeEventListener("turbo:load", this.pageRendered)
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
      if (this.confirmed.has(source) || this.stale()) this.request()
      this.confirmed.add(source)
    })
  }

  pageRendered = () => {
    if (this.stale()) this.request()
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
