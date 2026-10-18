# frozen_string_literal: true

require "test_helper"
require_relative "support/node_script"

# How chats--thread catches up (in node, against support/browser.js): what
# it asks #refresh for, where it lands when its history was re-rendered,
# and how a hard delete it missed leaves the screen. When it catches up is
# chats/recovery's (recovery_test.rb); what #refresh answers is
# ThreadRefreshTest's.
class ThreadCatchUpTest < ActiveSupport::TestCase
  include NodeScript

  def run_thread(script)
    run_node(<<~JAVASCRIPT)
      const page = browser.install()
      const Thread = loader.loadController("thread_controller.js")

      // createdAtUs in µs (to the microsecond the database keeps), updatedAtMs in ms.
      function bubble(id, { createdAtUs, updatedAtMs = createdAtUs / 1000 } = {}) {
        const dataset = { updatedAtMs: String(updatedAtMs) }
        if (createdAtUs !== undefined) dataset.createdAtUs = String(createdAtUs)
        return {
          id,
          isConnected: true,
          dataset,
          remove() { this.isConnected = false; thread.messageTargets = thread.messageTargets.filter((m) => m !== this) }
        }
      }

      const thread = new Thread()
      thread.refreshUrlValue = "/messages/7/refresh"
      thread.messageTargets = [
        bubble("message_1", { createdAtUs: 1_000_000, updatedAtMs: 9_500 }),   // edited last, at 9.5s
        bubble("message_2", { createdAtUs: 2_000_000 }),
        bubble("message_3", { createdAtUs: 3_000_123 })                        // the newest creation
      ]
      thread.messageTargets.forEach((message) => thread.trackLoadCursor(message))
      let scrolledToBottom = 0
      thread.scrollToBottom = () => scrolledToBottom++

      #{script}
    JAVASCRIPT
  end

  def async(script)
    "(async () => {\n#{script}\n})().catch((error) => { console.error(error); process.exit(1) })"
  end

  test "it asks for what was created after its newest bubble and what changed since its newest change, apart" do
    # One cursor can't do both: a message created at 4s and missed, while
    # message_1 was edited at 9.5s, is older than the newest change.
    run_thread(async(<<~JAVASCRIPT))
      thread.refreshThread()
      assert.strictEqual(page.requests.length, 1)
      assert.strictEqual(page.requests[0].url, "/messages/7/refresh?since=9500&after=3000123&from=1000000",
                         "no `history`: this scroller has no id, as in a thread view ejected before it did")
      assert.strictEqual(page.requests[0].options.headers.Accept, "text/vnd.turbo-stream.html")

      page.respond(page.requests[0], { body: "<turbo-stream action=\\"append\\"></turbo-stream>" })
      await page.settle()
      assert.strictEqual(page.rendered.length, 1)
      assert.strictEqual(scrolledToBottom, 0, "an append leaves the scroll to the stick-to-bottom rule")
    JAVASCRIPT
  end

  test "a thread re-rendered at its latest page opens at the bottom, as a fresh thread does" do
    run_thread(async(<<~JAVASCRIPT))
      thread.hasScrollerTarget = true
      thread.scrollerTarget = { id: "history_conversation_7" }
      window.Turbo.renderStreamMessage = () => {
        thread.messageTargets.slice().forEach((message) => message.remove())
        thread.messageTargets = [bubble("message_90", { createdAtUs: 90_000_000 })]
      }
      thread.refreshThread()
      assert.strictEqual(page.requests[0].url, "/messages/7/refresh?since=9500&after=3000123&from=1000000&history=1")
      page.respond(page.requests[0])
      await page.settle()
      assert.strictEqual(scrolledToBottom, 1)
    JAVASCRIPT
  end

  test "an empty thread asks from the epoch: its first message may be the one it missed" do
    run_thread(<<~JAVASCRIPT)
      const empty = new Thread()
      empty.refreshUrlValue = "/messages/7/refresh"
      empty.messageTargets = []
      empty.refreshThread()
      assert.strictEqual(page.requests.length, 1)
      assert.strictEqual(page.requests[0].url, "/messages/7/refresh?since=0&after=0")
    JAVASCRIPT
  end

  test "bubbles ejected before they carried their creation time ask on the one cursor they had" do
    run_thread(<<~JAVASCRIPT)
      const old = new Thread()
      old.refreshUrlValue = "/messages/7/refresh"
      old.messageTargets = [bubble("message_1", { updatedAtMs: 4_000 })]
      old.messageTargets.forEach((message) => old.trackLoadCursor(message))
      old.refreshThread()
      assert.strictEqual(page.requests[0].url, "/messages/7/refresh?since=4000")
    JAVASCRIPT
  end

  test "nothing to ask without a refresh URL" do
    run_thread(<<~JAVASCRIPT)
      const unwired = new Thread()
      unwired.messageTargets = thread.messageTargets
      unwired.refreshThread()
      assert.strictEqual(page.requests.length, 0)
    JAVASCRIPT
  end

  test "a hard delete it missed goes; what still exists, and what arrived after the server looked, stays" do
    run_thread(<<~JAVASCRIPT)
      thread.messageTargets.push(bubble("message_4", { createdAtUs: 9_000_000 }))   // live, after `until`
      thread.prune({ detail: { ids: ["message_1", "message_3"], until: 5_000_000 } })
      assert.deepStrictEqual(thread.messageTargets.map((message) => message.id), ["message_1", "message_3", "message_4"])
    JAVASCRIPT
  end

  test "the chats_prune stream action hands the thread the server's list" do
    run_thread(<<~JAVASCRIPT)
      thread.registerPruneStreamAction()
      const events = []
      const target = { dispatchEvent: (event) => events.push(event) }
      const stream = {
        targetElements: [target],
        getAttribute: (name) => ({ "data-ids": "message_1 message_3", "data-until": "5000" })[name]
      }
      window.Turbo.StreamActions.chats_prune.call(stream)

      assert.strictEqual(events.length, 1)
      assert.strictEqual(events[0].type, "chats:prune")
      assert.strictEqual(events[0].bubbles, true)
      assert.deepStrictEqual(events[0].detail, { ids: ["message_1", "message_3"], until: 5000 })
    JAVASCRIPT
  end
end
