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
      const { afterRendering, cancelStreamsFor, recoverMissedBroadcasts, renderStreamFrom } = loader.loadRecovery()
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

  # renderStreamFrom against a fake of Turbo's stream engine (page.turboStreams):
  # streams join <html>, are announced, and are performed when the test says.
  def run_streams(script)
    run_recovery(<<~JAVASCRIPT)
      (async () => {
        const turbo = page.turboStreams()
        const answer = (index) => page.respond(page.requests[index], {
          body: '<turbo-stream action="append" target="messages"><template>x</template></turbo-stream>' +
                '<turbo-stream action="chats_caught_up" target="messages"></turbo-stream>'
        })
        #{script}
      })().catch((error) => { console.error(error); process.exit(1) })
    JAVASCRIPT
  end

  test "a request that hangs (a network interruption) is aborted after 15s, and the next catch-up asks again" do
    run_streams(<<~JAVASCRIPT)
      let resolved = null
      renderStreamFrom("/messages/7/refresh?after=0").then((rendered) => { resolved = rendered })
      renderStreamFrom("/messages/7/refresh?after=0")
      assert.strictEqual(page.requests.length, 1, "while it is in flight, it stands in for the same request")

      page.advance(14_999); await page.settle()
      assert.strictEqual(page.requests[0].aborted, false)
      page.advance(1); await page.settle()
      assert.strictEqual(page.requests[0].aborted, true)
      assert.strictEqual(resolved, false)

      renderStreamFrom("/messages/7/refresh?after=0")
      assert.strictEqual(page.requests.length, 2, "the slot is free again")
    JAVASCRIPT
  end

  test "it resolves only once Turbo has applied what it rendered, however long that takes" do
    run_streams(<<~JAVASCRIPT)
      let resolved = null
      renderStreamFrom("/messages/7/refresh?after=0").then((rendered) => { resolved = rendered })
      answer(0)
      await page.settle()
      assert.strictEqual(turbo.pending().length, 2)

      page.advance(5_000); await page.settle()
      assert.strictEqual(resolved, null, "not while its streams wait to be performed, even past 2s")
      renderStreamFrom("/messages/7/refresh?after=0")
      assert.strictEqual(page.requests.length, 2, "past 2s, an unapplied answer no longer stands in for a new request")
      assert.strictEqual(page.requests[0].aborted, false, "and an answered request is never aborted")

      await turbo.applyStreams(); await page.settle()
      assert.strictEqual(resolved, true)
      assert.strictEqual(turbo.performed.length, 2)
    JAVASCRIPT
  end

  test "streams still waiting when their page is rendered again are dropped, and nothing is left watching" do
    run_streams(<<~JAVASCRIPT)
      const watchingBefore = page.observerCount()
      let wanted = true
      let resolved = null
      renderStreamFrom("/messages/7/refresh?after=0", { when: () => wanted }).then((rendered) => { resolved = rendered })
      answer(0)
      await page.settle()
      assert.strictEqual(page.observerCount(), watchingBefore + 1)

      wanted = false                                  // the thread rendered again…
      page.mutate(document.documentElement)           // …and <html> changed as it did
      page.advance(0)                                 // asked a task later
      await page.settle()
      assert.strictEqual(resolved, false)
      assert.strictEqual(turbo.pending().length, 0, "its leftover streams are gone")
      assert.strictEqual(page.observerCount(), watchingBefore, "and nothing watches for them")

      await turbo.applyStreams()
      assert.strictEqual(turbo.performed.length, 0, "a stream Turbo still had queued does nothing")
    JAVASCRIPT
  end

  test "an element away for an instant (Turbo carrying the dock across a visit) keeps its answer" do
    run_streams(<<~JAVASCRIPT)
      let wanted = true
      let resolved = null
      renderStreamFrom("/messages/7/refresh?after=0", { when: () => wanted }).then((rendered) => { resolved = rendered })
      answer(0)
      await page.settle()

      wanted = false                                  // detached by the visit…
      page.mutate(document.documentElement)           // (the body is replaced)
      wanted = true                                   // …and attached again, in the same task
      page.advance(0); await page.settle()
      assert.strictEqual(turbo.pending().length, 2, "its streams still wait")

      await turbo.applyStreams(); await page.settle()
      assert.strictEqual(resolved, true)
      assert.strictEqual(turbo.performed.length, 2)
    JAVASCRIPT
  end

  test "an answer that arrives while a page render has its element off the page waits for the render to end" do
    # A host's turbo:before-render may render asynchronously, so a permanent
    # element can be away for many tasks.
    run_streams(<<~JAVASCRIPT)
      let wanted = true
      let resolved = null
      renderStreamFrom("/messages/7/refresh?after=0", { when: () => wanted }).then((rendered) => { resolved = rendered })
      page.documentEvents.dispatch("turbo:before-render")
      wanted = false                                  // the dock is off the page…
      answer(0)                                       // …when the answer arrives
      page.advance(3_000); await page.settle()
      assert.strictEqual(turbo.streams.length, 0, "nothing rendered yet")
      assert.strictEqual(resolved, null, "and nothing decided")

      wanted = true                                   // the render puts it back…
      page.documentEvents.dispatch("turbo:render")    // …and ends
      page.advance(0); await page.settle()
      assert.strictEqual(turbo.pending().length, 2)
      await turbo.applyStreams(); await page.settle()
      assert.strictEqual(resolved, true)
    JAVASCRIPT
  end

  test "streams waiting through a page render are decided once it ends, and a render that never ends is bounded" do
    run_streams(<<~JAVASCRIPT)
      let wanted = true
      let resolved = null
      renderStreamFrom("/messages/7/refresh?after=0", { when: () => wanted }).then((rendered) => { resolved = rendered })
      answer(0)
      await page.settle()

      page.documentEvents.dispatch("turbo:before-render")
      wanted = false
      page.mutate(document.documentElement)           // the body goes…
      page.advance(5_000); await page.settle()
      assert.strictEqual(turbo.pending().length, 2, "kept while the render runs")

      page.advance(5_001); await page.settle()        // a render that never ended stops holding after 10s
      assert.strictEqual(turbo.pending().length, 0, "then decided: the element is gone")
      assert.strictEqual(resolved, false)

      let after = false
      afterRendering().then(() => { after = true })
      page.advance(0); await page.settle()
      assert.ok(after, "with no render running, a task later")
    JAVASCRIPT
  end

  test "overlapping page renders: nothing is decided until every one of them has ended" do
    run_streams(<<~JAVASCRIPT)
      let wanted = true
      let resolved = null
      renderStreamFrom("/messages/7/refresh?after=0", { when: () => wanted }).then((rendered) => { resolved = rendered })
      answer(0)
      await page.settle()

      page.documentEvents.dispatch("turbo:before-render")   // a first asynchronous render…
      page.documentEvents.dispatch("turbo:before-render")   // …and a second, before the first ends
      wanted = false
      page.mutate(document.documentElement)
      page.documentEvents.dispatch("turbo:render")          // the first ends; the second still has the window away
      page.advance(1_000); await page.settle()
      assert.strictEqual(turbo.pending().length, 2, "kept: a render is still out")

      let after = false
      afterRendering().then(() => { after = true })
      page.advance(0); await page.settle()
      assert.strictEqual(after, false, "still rendering")

      wanted = true
      page.documentEvents.dispatch("turbo:render")          // the second ends with the window back
      page.advance(0); await page.settle()
      assert.strictEqual(after, true)
      await turbo.applyStreams(); await page.settle()
      assert.strictEqual(resolved, true)
    JAVASCRIPT
  end

  test "what a render past its bound made give up is caught up anew when that render ends with the window back" do
    run_streams(<<~JAVASCRIPT)
      let wanted = true
      const retries = []
      renderStreamFrom("/messages/7/refresh?after=0", { when: () => wanted, retry: () => retries.push("again") })
      answer(0)
      await page.settle()

      page.documentEvents.dispatch("turbo:before-render")
      wanted = false                                       // the window is away…
      page.mutate(document.documentElement)
      page.advance(10_001); await page.settle()            // …longer than the bound
      assert.strictEqual(turbo.pending().length, 0, "given up")
      assert.deepStrictEqual(retries, [])

      wanted = true                                        // the render, late, brings it back
      page.documentEvents.dispatch("turbo:render")
      page.advance(0); await page.settle()
      assert.deepStrictEqual(retries, ["again"], "and it catches up anew")

      page.documentEvents.dispatch("turbo:before-render")
      page.documentEvents.dispatch("turbo:render")
      page.advance(0); await page.settle()
      assert.deepStrictEqual(retries, ["again"], "once")
    JAVASCRIPT
  end

  test "an answer given up for a window a late render never brings back is not retried" do
    run_streams(<<~JAVASCRIPT)
      const retries = []
      page.documentEvents.dispatch("turbo:before-render")
      renderStreamFrom("/messages/7/refresh?after=0", { when: () => false, retry: () => retries.push("again") })
      page.advance(10_001); await page.settle()            // overdue
      answer(0)                                            // arrives with the window away
      await page.settle(); page.advance(0); await page.settle()
      page.documentEvents.dispatch("turbo:render")         // the late render ends; the window never came back
      page.advance(0); await page.settle()
      assert.deepStrictEqual(retries, [])
    JAVASCRIPT
  end

  test "a timed-out render's late end is paired with it, not with the render after it (first in, first out)" do
    run_streams(<<~JAVASCRIPT)
      afterRendering()                                      // (watching page renders, as a connected thread is)
      page.documentEvents.dispatch("turbo:before-render")   // R1, which will run late…
      page.advance(10_001)                                  // …past its bound
      page.documentEvents.dispatch("turbo:before-render")   // R2 starts

      let after = false
      afterRendering().then(() => { after = true })
      page.documentEvents.dispatch("turbo:render")          // R1's late end
      page.advance(0); await page.settle()
      assert.strictEqual(after, false, "R2 still holds things up")

      page.documentEvents.dispatch("turbo:render")          // R2's end
      page.advance(0); await page.settle()
      assert.strictEqual(after, true)
    JAVASCRIPT
  end

  test "a catch-up given up by several of its streams is remembered, and retried, once" do
    run_streams(<<~JAVASCRIPT)
      let wanted = true
      const retries = []
      const thread = {}
      renderStreamFrom("/messages/7/refresh?after=0", { when: () => wanted, key: thread, retry: () => retries.push("again") })
      answer(0)                                             // two streams
      await page.settle()

      page.documentEvents.dispatch("turbo:before-render")
      wanted = false
      page.advance(10_001); await page.settle()             // the render is overdue
      await turbo.applyStreams(); await page.settle()       // both streams reach their guards and give up
      assert.strictEqual(turbo.performed.length, 0)

      wanted = true
      page.documentEvents.dispatch("turbo:render")          // the late render ends with the window back
      page.advance(0); await page.settle()
      page.documentEvents.dispatch("turbo:before-render")
      page.documentEvents.dispatch("turbo:render")
      page.advance(0); await page.settle()
      assert.deepStrictEqual(retries, ["again"])
    JAVASCRIPT
  end

  test "a render that never ends, and what it made give up, are forgotten after 60s" do
    run_streams(<<~JAVASCRIPT)
      const retries = []
      afterRendering()
      page.documentEvents.dispatch("turbo:before-render")   // never ends
      page.advance(10_001)
      let wanted = false
      renderStreamFrom("/messages/7/refresh?after=0", { when: () => wanted, retry: () => retries.push("again") })
      answer(0)
      await page.settle(); page.advance(0); await page.settle()  // given up, remembered

      page.advance(60_000); await page.settle()             // forgotten: the render, and the retry
      wanted = true
      page.documentEvents.dispatch("turbo:before-render")   // a later, unrelated render…
      page.documentEvents.dispatch("turbo:render")          // …is paired with itself, not the forgotten one
      page.advance(0); await page.settle()
      assert.deepStrictEqual(retries, [], "nothing old is retried")

      let after = false
      afterRendering().then(() => { after = true })
      page.advance(0); await page.settle()
      assert.ok(after, "and nothing holds things up")
    JAVASCRIPT
  end

  test "at most one unapplied answer per key: a newer one, or cancelStreamsFor, drops the older's leftovers" do
    run_streams(<<~JAVASCRIPT)
      const thread = {}
      const watchingBefore = page.observerCount()
      const results = []
      for (let index = 0; index < 5; index++) {
        renderStreamFrom(`/messages/7/refresh?after=${index}`, { key: thread }).then((rendered) => results.push(rendered))
        answer(index)
        await page.settle()
      }
      assert.deepStrictEqual(results, [false, false, false, false], "each newer answer cancelled the one before")
      assert.strictEqual(turbo.pending().length, 2, "only the newest answer's streams wait")
      assert.strictEqual(page.observerCount(), watchingBefore + 1)

      cancelStreamsFor(thread)                        // the thread disconnects
      await page.settle()
      assert.deepStrictEqual(results, [false, false, false, false, false])
      assert.strictEqual(turbo.pending().length, 0)
      assert.strictEqual(page.observerCount(), watchingBefore)
    JAVASCRIPT
  end

  test "an answer no longer wanted when it arrives is never rendered" do
    run_streams(<<~JAVASCRIPT)
      let resolved = null
      renderStreamFrom("/messages/7/refresh?after=0", { when: () => false }).then((rendered) => { resolved = rendered })
      answer(0)
      await page.settle()
      assert.strictEqual(resolved, false)
      assert.strictEqual(turbo.streams.length, 0)
    JAVASCRIPT
  end

  test "a host's own stream, rendered in the same moment, is never held back by an answer's guard" do
    run_streams(<<~JAVASCRIPT)
      let wanted = true
      renderStreamFrom("/messages/7/refresh?after=0", { when: () => wanted })
      answer(0)
      await page.settle()
      turbo.foreign()                                 // the host renders a stream of its own
      wanted = false                                  // and the thread renders again before Turbo applies anything

      await turbo.applyStreams()
      const performed = turbo.performed.map((stream) => stream.attributes)
      assert.deepStrictEqual(performed, [{ action: "append" }], "the host's stream ran; the answer's didn't")
      assert.ok(turbo.streams.slice(0, 2).every((stream) => stream.attributes["data-chats-answer"]), "the answer's were marked")
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
        assert.strictEqual(page.rendered.length, 1)
        assert.match(page.rendered[0], /^<turbo-stream data-chats-answer="[^"]+" action=\\"replace\\"><\\/turbo-stream>$/, "rendered, marked as this answer's")

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
