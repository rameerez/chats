# frozen_string_literal: true

require "test_helper"
require_relative "support/node_script"

# chats/recovery: when a live surface catches up on broadcasts it may have
# missed, and — just as important — when it doesn't. Run in node against a
# fake page (support/browser.js): a deterministic clock, visibility,
# network events, and stream sources that confirm and drop like
# turbo-rails' <turbo-cable-stream-source>.
class RecoveryTest < ActiveSupport::TestCase
  include NodeScript

  # Each script gets `page` (the fake), `watch(sources)` (starts watching an
  # element holding them, returns the catch-up count and the stop function).
  def run_recovery(script)
    run_node(<<~JAVASCRIPT)
      const page = browser.install()
      const { recoverMissedBroadcasts, renderStreamFrom } = loader.loadRecovery()
      function watch(sources, options) {
        const caught = { count: 0 }
        caught.stop = recoverMissedBroadcasts(page.element({ sources }), () => caught.count++, options)
        return caught
      }
      #{script}
    JAVASCRIPT
  end

  test "a healthy, visible page never fetches: no polling" do
    run_recovery(<<~JAVASCRIPT)
      const source = page.streamSource()
      const caught = watch([source])

      source.confirm()                 // the first confirmation is the page's own subscribe
      page.advance(60 * 60_000)        // an hour on screen
      assert.strictEqual(caught.count, 0)
      assert.strictEqual(page.pendingTimers(), 0, "nothing is scheduled while all is well")
    JAVASCRIPT
  end

  test "a stream that drops and confirms again catches up once, after the triggers settle" do
    run_recovery(<<~JAVASCRIPT)
      const source = page.streamSource()
      const caught = watch([source])
      source.confirm()

      source.drop()
      page.advance(3_000)
      assert.strictEqual(caught.count, 0, "nothing while the socket is down")

      source.confirm()
      page.advance(249)
      assert.strictEqual(caught.count, 0, "not before the triggers have had 250ms to come together")
      page.advance(1)
      assert.strictEqual(caught.count, 1)
    JAVASCRIPT
  end

  test "a confirmation with no drop reported is a reconnect too: Action Cable reopening a quiet socket" do
    # ConnectionMonitor#reopen swaps the old socket's handlers out before its
    # close event can arrive, so subscribers hear only "connected" again.
    run_recovery(<<~JAVASCRIPT)
      const source = page.streamSource()
      const caught = watch([source])
      source.confirm()

      source.confirm()
      page.advance(250)
      assert.strictEqual(caught.count, 1)
    JAVASCRIPT
  end

  test "a page restored from Turbo's snapshot cache catches up as soon as its stream is live" do
    run_recovery(<<~JAVASCRIPT)
      // Leaving a page: Turbo announces the snapshot, then clones the page.
      const leaving = page.streamSource()
      const permanent = page.streamSource({ permanent: true })
      watch([leaving])
      page.documentEvents.dispatch("turbo:before-cache")
      assert.ok(leaving.hasAttribute("chats-cached"), "marked as it goes into the cache")
      assert.ok(!permanent.hasAttribute("chats-cached"), "a permanent element is carried live, never restored")

      // Coming back to it (a back navigation, a Hotwire Native stack pop).
      const restored = page.streamSource({ cached: true })
      const caught = watch([restored])
      assert.ok(!restored.hasAttribute("chats-cached"), "the mark is consumed")
      page.advance(1_000)
      assert.strictEqual(caught.count, 0, "not before the stream is live again")

      restored.confirm()
      page.advance(250)
      assert.strictEqual(caught.count, 1)
    JAVASCRIPT
  end

  test "a page Turbo fetched fresh fetches nothing more when its stream first connects" do
    run_recovery(<<~JAVASCRIPT)
      const fresh = page.streamSource()
      const caught = watch([fresh])
      fresh.confirm()
      page.advance(1_000)
      assert.strictEqual(caught.count, 0)
    JAVASCRIPT
  end

  test "coming back after 10 seconds hidden catches up; a shorter glance away does not" do
    run_recovery(<<~JAVASCRIPT)
      const caught = watch([page.streamSource()])

      page.hide()
      page.advance(9_999)
      page.show()
      page.advance(1_000)
      assert.strictEqual(caught.count, 0, "under 10s the socket and its frames survive")

      page.hide()
      page.advance(10_000)
      page.show()
      page.advance(250)
      assert.strictEqual(caught.count, 1)
    JAVASCRIPT
  end

  test "a page that loads hidden counts its hidden time from the start" do
    run_recovery(<<~JAVASCRIPT)
      document.visibilityState = "hidden"
      const caught = watch([page.streamSource()])
      page.advance(60_000)
      page.show()
      page.advance(250)
      assert.strictEqual(caught.count, 1)
    JAVASCRIPT
  end

  test "a hidden page never fetches; what it missed waits until it is seen, however briefly it was away" do
    run_recovery(<<~JAVASCRIPT)
      const source = page.streamSource()
      const caught = watch([source])
      source.confirm()

      page.hide()
      source.drop()
      source.confirm()                 // reconnected in the background
      page.advance(60_000)
      assert.strictEqual(caught.count, 0)

      page.show()
      page.advance(250)
      assert.strictEqual(caught.count, 1)
    JAVASCRIPT
  end

  test "a catch-up whose timer fires once the page is hidden again waits for it to be seen" do
    run_recovery(<<~JAVASCRIPT)
      const source = page.streamSource()
      const caught = watch([source])
      source.confirm()

      source.confirm()
      page.advance(100)
      document.visibilityState = "hidden"   // hidden before the timer fires, no event yet
      page.advance(500)
      assert.strictEqual(caught.count, 0)

      page.show()
      page.advance(250)
      assert.strictEqual(caught.count, 1)
    JAVASCRIPT
  end

  test "triggers that come together make one catch-up" do
    run_recovery(<<~JAVASCRIPT)
      const source = page.streamSource()
      const caught = watch([source])
      source.confirm()

      page.hide()
      page.advance(30_000)
      page.show()                       // back from the background…
      page.advance(100)
      source.confirm()                  // …and the socket reopens right after
      page.restoreFromBfcache()
      page.advance(250)
      assert.strictEqual(caught.count, 1)
      page.advance(60_000)
      assert.strictEqual(caught.count, 1, "and nothing more after it")
    JAVASCRIPT
  end

  test "catch-ups are at least five seconds apart, so a flapping connection is no fetch loop" do
    run_recovery(<<~JAVASCRIPT)
      const source = page.streamSource()
      const caught = watch([source])
      source.confirm()

      source.confirm()
      page.advance(250)
      assert.strictEqual(caught.count, 1)
      const first = page.now

      source.confirm()                  // a reconnect a second later is a new gap: caught…
      page.advance(1_000)
      assert.strictEqual(caught.count, 1, "…but not sooner than 5s after the last")
      page.advance(first + 5_000 - page.now)
      assert.strictEqual(caught.count, 2)

      for (let i = 0; i < 20; i++) { source.drop(); source.confirm(); page.advance(1_000) }
      assert.ok(caught.count <= 2 + 4, `20 reconnects in 20s fetched ${caught.count - 2} times`)
    JAVASCRIPT
  end

  test "the network coming back asks Action Cable to check its socket now, and catches up anyway" do
    # After a short outage the socket can still look open (so the check
    # leaves it alone) while what was sent during the outage is gone.
    run_recovery(<<~JAVASCRIPT)
      const source = page.streamSource()
      const caught = watch([source])
      source.confirm()

      page.goOnline()
      assert.strictEqual(page.monitor.checks, 1, "ConnectionMonitor#visibilityDidChange, nudged")
      page.advance(250)
      assert.strictEqual(caught.count, 1)

      source.confirm()                  // the check found it dead and reopened it: a new gap
      page.advance(1_000)
      assert.strictEqual(caught.count, 1, "within the 5s floor…")
      page.advance(4_000)
      assert.strictEqual(caught.count, 2, "…then once more")
    JAVASCRIPT
  end

  test "coming online together with a reconnect is one catch-up" do
    run_recovery(<<~JAVASCRIPT)
      const source = page.streamSource()
      const caught = watch([source])
      source.confirm()

      page.goOnline()
      source.confirm()
      page.advance(60_000)
      assert.strictEqual(caught.count, 1)
    JAVASCRIPT
  end

  test "without a monitor to ask, coming online still catches up" do
    run_recovery(<<~JAVASCRIPT)
      const caught = watch([page.streamSource({ monitored: false })])
      page.goOnline()
      page.advance(250)
      assert.strictEqual(caught.count, 1)
    JAVASCRIPT
  end

  test "a back/forward cache restore checks the socket and catches up; a first show does neither" do
    run_recovery(<<~JAVASCRIPT)
      const caught = watch([page.streamSource()])

      page.firstShow()
      page.advance(1_000)
      assert.strictEqual(caught.count, 0)
      assert.strictEqual(page.monitor.checks, 0)

      page.restoreFromBfcache()
      page.advance(250)
      assert.strictEqual(caught.count, 1)
      assert.strictEqual(page.monitor.checks, 1)
    JAVASCRIPT
  end

  test "a Turbo preview never catches up: the real page is on its way" do
    run_recovery(<<~JAVASCRIPT)
      const source = page.streamSource({ cached: true })
      const caught = watch([source])
      page.htmlAttributes.add("data-turbo-preview")
      source.confirm()
      page.advance(1_000)
      assert.strictEqual(caught.count, 0)
    JAVASCRIPT
  end

  test "stopping removes every listener and drops a catch-up still waiting" do
    run_recovery(<<~JAVASCRIPT)
      const source = page.streamSource()
      const caught = watch([source])
      assert.strictEqual(page.documentEvents.count("visibilitychange"), 1)
      assert.strictEqual(page.windowEvents.count("online"), 1)
      assert.strictEqual(page.windowEvents.count("pageshow"), 1)

      source.confirm()
      source.confirm()
      caught.stop()
      page.advance(10_000)
      assert.strictEqual(caught.count, 0)

      assert.strictEqual(page.documentEvents.count("visibilitychange"), 0)
      assert.strictEqual(page.windowEvents.count("online"), 0)
      assert.strictEqual(page.windowEvents.count("pageshow"), 0)
      source.confirm()
      page.advance(10_000)
      assert.strictEqual(caught.count, 0, "the observer is gone too")
    JAVASCRIPT
  end

  test "`sources:` narrows what is watched: the dock watches its own stream, not its windows'" do
    run_recovery(<<~JAVASCRIPT)
      const own = page.streamSource()
      const windowThread = page.streamSource()
      const caught = { count: 0 }
      recoverMissedBroadcasts(page.element({ sources: [own, windowThread], direct: [own] }),
                              () => caught.count++, { sources: ":scope > turbo-cable-stream-source" })
      own.confirm(); windowThread.confirm()

      windowThread.confirm()
      page.advance(1_000)
      assert.strictEqual(caught.count, 0)

      own.confirm()
      page.advance(250)
      assert.strictEqual(caught.count, 1)
    JAVASCRIPT
  end

  test "a morph never strips `connected` from a stream source, and only that attribute is kept" do
    run_recovery(<<~JAVASCRIPT)
      watch([page.streamSource()])
      watch([page.streamSource()])
      assert.strictEqual(page.documentEvents.count("turbo:before-morph-attribute"), 1, "installed once per page")
      assert.strictEqual(page.documentEvents.count("turbo:before-cache"), 1, "installed once per page")

      const source = { localName: "turbo-cable-stream-source" }
      const kept = page.documentEvents.dispatch("turbo:before-morph-attribute", { target: source, detail: { attributeName: "connected", mutationType: "remove" } })
      assert.strictEqual(kept.defaultPrevented, true)

      const signed = page.documentEvents.dispatch("turbo:before-morph-attribute", { target: source, detail: { attributeName: "signed-stream-name" } })
      assert.strictEqual(signed.defaultPrevented, false)

      const other = page.documentEvents.dispatch("turbo:before-morph-attribute", { target: { localName: "div" }, detail: { attributeName: "connected" } })
      assert.strictEqual(other.defaultPrevented, false)
    JAVASCRIPT
  end

  test "renderStreamFrom renders a Turbo Stream, makes the same request once at a time, and ignores anything else" do
    run_recovery(<<~JAVASCRIPT)
      (async () => {
        renderStreamFrom("/messages/badge")
        renderStreamFrom("/messages/badge")
        assert.strictEqual(page.requests.length, 1, "two at once are one request")
        assert.strictEqual(page.requests[0].options.headers.Accept, "text/vnd.turbo-stream.html")
        page.respond(page.requests[0], { body: "<turbo-stream action=\\"replace\\"></turbo-stream>" })
        await page.settle()
        assert.deepStrictEqual(page.rendered, ["<turbo-stream action=\\"replace\\"></turbo-stream>"])

        renderStreamFrom("/messages/badge")
        assert.strictEqual(page.requests.length, 2, "once answered, the next one is a new request")
        page.respond(page.requests[1], { type: "text/html; charset=utf-8", body: "<html>Sign in</html>" })
        await page.settle()

        renderStreamFrom("/messages/badge")
        page.respond(page.requests[2], { status: 500 })
        await page.settle()

        renderStreamFrom("/messages/badge")
        page.requests[3].resolve(Promise.reject(new Error("offline")))
        await page.settle()

        assert.strictEqual(page.rendered.length, 1, "a sign-in page, an error and no network render nothing")
      })().catch((error) => { console.error(error); process.exit(1) })
    JAVASCRIPT
  end
end
