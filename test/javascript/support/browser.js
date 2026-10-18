// A fake page for the engine's JavaScript: just enough document, window,
// clock, MutationObserver and <turbo-cable-stream-source> to drive
// chats/recovery and the controllers built on it, deterministically.
//
//   const page = browser.install()   // sets the globals; call before loading
//   const source = page.streamSource()
//   source.confirm()                  // Action Cable confirmed the subscription
//   source.drop()                     // the socket closed
//   page.hide(); page.advance(11_000); page.show()
//   page.goOnline(); page.restoreFromBfcache()

function listeners() {
  const handlers = {}
  return {
    handlers,
    addEventListener(name, handler) { (handlers[name] ||= []).push(handler) },
    removeEventListener(name, handler) { handlers[name] = (handlers[name] || []).filter((h) => h !== handler) },
    dispatch(name, event = {}) {
      const dispatched = { type: name, defaultPrevented: false, preventDefault() { this.defaultPrevented = true }, ...event }
      ;(handlers[name] || []).slice().forEach((handler) => handler(dispatched))
      return dispatched
    },
    count(name) { return (handlers[name] || []).length }
  }
}

function install() {
  let now = 1_000_000
  let timers = []
  let nextTimer = 1

  global.setTimeout = (callback, wait = 0) => {
    const id = nextTimer++
    timers.push({ id, at: now + wait, callback })
    return id
  }
  global.clearTimeout = (id) => { timers = timers.filter((timer) => timer.id !== id) }
  Date.now = () => now

  const observers = new Set()
  global.MutationObserver = class {
    constructor(callback) { this.callback = callback; this.targets = new Set() }
    observe(target) { this.targets.add(target); observers.add(this) }
    disconnect() { this.targets.clear(); observers.delete(this) }
  }
  const mutated = (target) => {
    observers.forEach((observer) => { if (observer.targets.has(target)) observer.callback([{ target }]) })
  }

  const documentEvents = listeners()
  const htmlAttributes = new Set()
  global.document = {
    ...documentEvents,
    visibilityState: "visible",
    activeElement: null,
    baseURI: "https://example.test/messages",
    querySelectorAll: (selector) => (selector === "turbo-cable-stream-source" ? page.allSources : []),
    documentElement: {
      hasAttribute: (name) => htmlAttributes.has(name),
      setAttribute: (name) => htmlAttributes.add(name),
      removeAttribute: (name) => htmlAttributes.delete(name)
    }
  }

  const rendered = []
  const refreshes = []
  const windowEvents = listeners()
  global.window = {
    ...windowEvents,
    Turbo: {
      StreamActions: {},
      renderStreamMessage: (html) => rendered.push(html),
      session: { refresh: (url, options) => refreshes.push({ url, options }) }
    }
  }

  const requests = []
  global.fetch = (url, options) => new Promise((resolve) => requests.push({ url, options, resolve }))

  const monitor = { checks: 0, visibilityDidChange() { this.checks++ } }

  const page = {
    allSources: [],
    rendered,
    refreshes,
    requests,
    monitor,
    documentEvents,
    windowEvents,
    htmlAttributes,

    get now() { return now },

    // Runs every timer due within +ms+, in order, moving the clock along.
    advance(ms) {
      const until = now + ms
      for (;;) {
        const due = timers.filter((timer) => timer.at <= until).sort((a, b) => a.at - b.at)[0]
        if (!due) break
        timers = timers.filter((timer) => timer !== due)
        now = due.at
        due.callback()
      }
      now = until
    },

    pendingTimers: () => timers.length,

    // Tells the MutationObservers watching +target+ that it changed.
    mutate: (target) => mutated(target),

    hide() {
      document.visibilityState = "hidden"
      documentEvents.dispatch("visibilitychange")
    },

    show() {
      document.visibilityState = "visible"
      documentEvents.dispatch("visibilitychange")
    },

    goOnline() { windowEvents.dispatch("online") },
    restoreFromBfcache() { windowEvents.dispatch("pageshow", { persisted: true }) },
    firstShow() { windowEvents.dispatch("pageshow", { persisted: false }) },

    // A <turbo-cable-stream-source>. `cached: true` is one restored from
    // Turbo's snapshot cache (marked as it went in); `permanent: true` one
    // inside a data-turbo-permanent element.
    streamSource({ cached = false, permanent = false, monitored = true } = {}) {
      const attributes = new Set(cached ? ["chats-cached"] : [])
      const source = {
        localName: "turbo-cable-stream-source",
        attributes,
        subscription: monitored ? { consumer: { connection: { monitor } } } : undefined,
        hasAttribute: (name) => attributes.has(name),
        setAttribute: (name) => attributes.add(name),
        removeAttribute: (name) => attributes.delete(name),
        closest: (selector) => (permanent && selector === "[data-turbo-permanent]" ? {} : null),
        confirm() { attributes.add("connected"); mutated(this) },
        drop() { attributes.delete("connected"); mutated(this) }
      }
      page.allSources.push(source)
      return source
    },

    // An element holding +sources+; `direct` ones answer the dock's
    // `:scope > turbo-cable-stream-source` selector.
    element({ sources = [], direct = sources } = {}) {
      return {
        isConnected: true,
        querySelectorAll(selector) {
          if (selector === "turbo-cable-stream-source") return sources
          if (selector === ":scope > turbo-cable-stream-source") return direct
          return []
        }
      }
    },

    // A fetch() answer.
    respond(request, { status = 200, type = "text/vnd.turbo-stream.html; charset=utf-8", body = "<turbo-stream></turbo-stream>" } = {}) {
      request.resolve({
        ok: status >= 200 && status < 300,
        status,
        headers: { get: (name) => (name.toLowerCase() === "content-type" ? type : null) },
        text: () => Promise.resolve(body)
      })
    },

    // Lets every resolved promise run its callbacks.
    settle: () => new Promise((resolve) => setImmediate(resolve))
  }
  return page
}

module.exports = { install }
