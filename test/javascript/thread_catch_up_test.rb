# frozen_string_literal: true

require "test_helper"
require_relative "support/node_script"

# How chats--thread catches up (in node, against support/browser.js): the
# cursors it keeps and sends, that only a complete render or an answer that
# arrived moves them (never a live bubble), where it lands when its history
# was re-rendered, and how a hard delete it missed leaves the screen. When
# it catches up is chats/recovery's (recovery_test.rb); what #refresh
# answers is MissedBroadcastRecoveryTest's.
class ThreadCatchUpTest < ActiveSupport::TestCase
  include NodeScript

  # µs: 1s = 1_000_000.
  def run_thread(script)
    run_node(<<~JAVASCRIPT)
      const page = browser.install()
      const Thread = loader.loadController("thread_controller.js")

      // A bubble as the partial renders it; `legacyMs` is one ejected
      // before the microsecond cursors, with only data-updated-at-ms.
      function bubble(id, { createdAtUs, updatedAtUs = createdAtUs, legacyMs } = {}) {
        const dataset = legacyMs === undefined
          ? { messageId: String(id), createdAtUs: String(createdAtUs), updatedAtUs: String(updatedAtUs) }
          : { updatedAtMs: String(legacyMs) }
        return {
          id: `message_${id}`,
          isConnected: true,
          dataset,
          remove() { this.isConnected = false; thread.messageTargets = thread.messageTargets.filter((m) => m !== this) }
        }
      }

      // What connect() does with the cursors, on a thread rendered with +bubbles+.
      function rendered(bubbles, element = { dataset: {} }) {
        const controller = new Thread()
        controller.refreshUrlValue = "/messages/7/refresh"
        controller.element = element
        controller.messageTargets = bubbles
        controller.messageTargets.forEach((message) => controller.trackLegacyCursor(message))
        controller.caughtUp({ detail: controller.storedCursors() || controller.cursorsOfRender() })
        return controller
      }

      // A bubble arriving on the live stream: on screen, cursors untouched.
      function live(controller, message) {
        controller.messageTargets.push(message)
        controller.trackLegacyCursor(message)
      }

      const asked = (index = 0) => Object.fromEntries(new URL(page.requests[index].url, "https://example.test").searchParams)

      const thread = rendered([
        bubble(1, { createdAtUs: 1_000_000, updatedAtUs: 9_500_000 }),   // edited last, at 9.5s
        bubble(2, { createdAtUs: 2_000_000 }),
        bubble(3, { createdAtUs: 3_000_123 })                            // the newest creation
      ])
      let scrolledToBottom = 0
      thread.scrollToBottom = () => scrolledToBottom++

      #{script}
    JAVASCRIPT
  end

  def async(script)
    "(async () => {\n#{script}\n})().catch((error) => { console.error(error); process.exit(1) })"
  end

  test "a rendered thread asks for what was created after its newest bubble and what changed since its newest change" do
    run_thread(async(<<~JAVASCRIPT))
      thread.refreshThread()
      assert.strictEqual(page.requests.length, 1)
      assert.deepStrictEqual(asked(), { after: "3000123", changed: "9500000", after_ids: "3", changed_ids: "1", from: "1000000" },
                             "no `history`: this scroller has no id, as in a thread view ejected before it did")
      assert.strictEqual(page.requests[0].options.headers.Accept, "text/vnd.turbo-stream.html")

      page.respond(page.requests[0], { body: "<turbo-stream action=\\"append\\"></turbo-stream>" })
      await page.settle()
      assert.strictEqual(page.rendered.length, 1)
      assert.strictEqual(scrolledToBottom, 0, "an append leaves the scroll to the stick-to-bottom rule")
    JAVASCRIPT
  end

  test "a missed message, then a live one: the live one never moves the creation cursor past the missed one" do
    # B was created at 15s while the socket was down; C arrived live at 20s.
    run_thread(<<~JAVASCRIPT)
      live(thread, bubble(20, { createdAtUs: 20_000_000 }))
      thread.refreshThread()
      assert.strictEqual(asked().after, "3000123", "still the last complete render: B (15s) is after it")
      assert.strictEqual(asked().after_ids, "3,20", "C is on screen, named so it isn't sent again")
    JAVASCRIPT
  end

  test "a missed edit, then a live edit: the live one never moves the change cursor past the missed one" do
    # Bubble 2 was edited at 12s while the socket was down; bubble 3's edit
    # at 14s arrived live (a replaced bubble).
    run_thread(<<~JAVASCRIPT)
      thread.messageTargets[2] = bubble(3, { createdAtUs: 3_000_123, updatedAtUs: 14_000_000 })
      thread.refreshThread()
      assert.strictEqual(asked().changed, "9500000", "still the last complete render: 2's edit (12s) is after it")
      assert.strictEqual(asked().changed_ids, "1")
    JAVASCRIPT
  end

  test "an answer that arrived moves the cursors; one that never came leaves them" do
    run_thread(async(<<~JAVASCRIPT))
      thread.registerCaughtUpStreamAction()
      thread.refreshThread()
      page.requests[0].resolve(Promise.reject(new Error("offline")))
      await page.settle()
      thread.refreshThread()
      assert.strictEqual(asked(1).after, "3000123", "a failed catch-up moves nothing")

      const events = []
      const stream = {
        targetElements: [{ dispatchEvent: (event) => { events.push(event); thread.caughtUp(event) } }],
        getAttribute: (name) => ({ "data-after": "15000000", "data-changed": "15000000", "data-changed-ids": "15" })[name]
      }
      window.Turbo.StreamActions.chats_caught_up.call(stream)
      assert.strictEqual(events[0].type, "chats:caught-up")
      assert.strictEqual(events[0].bubbles, true)
      assert.deepStrictEqual(thread.reconciled, { after: 15_000_000, changed: 15_000_000, changedIds: ["15"] })
      assert.strictEqual(thread.element.dataset.chatsReconciled, JSON.stringify(thread.reconciled), "kept on the element")
    JAVASCRIPT
  end

  test "a thread that reconnects keeps the cursors it had, not the live bubbles on screen" do
    # The dock moves its windows on every Turbo visit; a snapshot restore
    # clones the element. Either way the controller connects again.
    run_thread(<<~JAVASCRIPT)
      live(thread, bubble(20, { createdAtUs: 20_000_000 }))
      const again = rendered(thread.messageTargets, thread.element)
      assert.deepStrictEqual(again.reconciled, { after: 3_000_123, changed: 9_500_000, changedIds: ["1"] })
    JAVASCRIPT
  end

  test "a thread re-rendered at its latest page opens at the bottom, and asks once more from there" do
    run_thread(async(<<~JAVASCRIPT))
      thread.hasScrollerTarget = true
      thread.scrollerTarget = { id: "history_conversation_7" }
      window.Turbo.renderStreamMessage = () => {
        thread.messageTargets.slice().forEach((message) => message.remove())
        thread.messageTargets = [bubble(90, { createdAtUs: 90_000_000 })]
        thread.caughtUp({ detail: { after: 90_000_000, changed: 90_000_000, changedIds: ["90"] } })
      }
      thread.refreshThread()
      assert.strictEqual(asked().history, "1")
      page.respond(page.requests[0])
      await page.settle()
      assert.strictEqual(scrolledToBottom, 1)
      assert.strictEqual(page.requests.length, 2, "anything that came live during the re-render is asked for")
      assert.strictEqual(asked(1).after, "90000000")

      window.Turbo.renderStreamMessage = () => {
        thread.messageTargets.slice().forEach((message) => message.remove())
        thread.messageTargets = [bubble(91, { createdAtUs: 91_000_000 })]
      }
      page.respond(page.requests[1])
      await page.settle()
      assert.strictEqual(page.requests.length, 2, "once, not in a loop")
    JAVASCRIPT
  end

  test "an empty thread asks from the epoch: its first message may be the one it missed" do
    run_thread(<<~JAVASCRIPT)
      rendered([]).refreshThread()
      assert.deepStrictEqual(asked(), { after: "0", changed: "0" })
    JAVASCRIPT
  end

  test "two bubbles in one instant are both named, so the server can tell them from one it missed" do
    run_thread(<<~JAVASCRIPT)
      rendered([
        bubble(2, { createdAtUs: 2_000_000, updatedAtUs: 5_000_001 }),   // edited in that instant
        bubble(4, { createdAtUs: 5_000_001 }),
        bubble(5, { createdAtUs: 5_000_001 })
      ]).refreshThread()
      assert.strictEqual(asked().after, "5000001")
      assert.strictEqual(asked().after_ids, "4,5")
      assert.strictEqual(asked().changed, "5000001")
      assert.strictEqual(asked().changed_ids, "2,4,5")
    JAVASCRIPT
  end

  test "past 200 bubbles to name, it asks for the whole history instead" do
    run_thread(<<~JAVASCRIPT)
      for (let i = 0; i < 200; i++) live(thread, bubble(100 + i, { createdAtUs: 4_000_000 + i }))
      thread.refreshThread()
      assert.strictEqual(asked().full, "1")
      assert.strictEqual(asked().after_ids, undefined, "and doesn't send the list")
      assert.strictEqual(asked().changed_ids, undefined)
    JAVASCRIPT
  end

  test "bubbles ejected before the microsecond cursors ask on the one cursor they had" do
    run_thread(<<~JAVASCRIPT)
      rendered([bubble(1, { legacyMs: 4_000 })]).refreshThread()
      assert.deepStrictEqual(asked(), { since: "4000" })
    JAVASCRIPT
  end

  test "nothing to ask without a refresh URL" do
    run_thread(<<~JAVASCRIPT)
      thread.refreshUrlValue = ""
      thread.refreshThread()
      assert.strictEqual(page.requests.length, 0)
    JAVASCRIPT
  end

  test "a hard delete it missed goes; what still exists, and what arrived after the server looked, stays" do
    run_thread(<<~JAVASCRIPT)
      thread.messageTargets.push(bubble(4, { createdAtUs: 9_000_000 }))   // live, after `until`
      thread.prune({ detail: { ids: ["message_1", "message_3"], until: 5_000_000 } })
      assert.deepStrictEqual(thread.messageTargets.map((message) => message.id), ["message_1", "message_3", "message_4"])
    JAVASCRIPT
  end

  test "the chats_prune stream action hands the thread the server's list" do
    run_thread(<<~JAVASCRIPT)
      thread.registerPruneStreamAction()
      const events = []
      const stream = {
        targetElements: [{ dispatchEvent: (event) => events.push(event) }],
        getAttribute: (name) => ({ "data-ids": "message_1 message_3", "data-until": "5000" })[name]
      }
      window.Turbo.StreamActions.chats_prune.call(stream)

      assert.strictEqual(events[0].type, "chats:prune")
      assert.strictEqual(events[0].bubbles, true)
      assert.deepStrictEqual(events[0].detail, { ids: ["message_1", "message_3"], until: 5000 })
    JAVASCRIPT
  end
end
