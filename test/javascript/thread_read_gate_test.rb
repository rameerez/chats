# frozen_string_literal: true

require "test_helper"
require "open3"

# The thread controller's read gate, run in node against plain fakes: a
# thread inside a dock window may post #read only while the dock says the
# window is expanded AND the viewer is engaged with it — checked again when
# the delayed read fires, and never trusting geometry alone (a folded
# window's scroller kept a few pixels of padding, which passed a
# clientHeight check and read a conversation nobody was looking at).
class ThreadReadGateTest < ActiveSupport::TestCase
  test "a minimized or unengaged dock window never posts a read, even when the timer was already set" do
    skip "node is not available" unless node_available?

    stdout, stderr, status = Open3.capture3(
      "node",
      "-",
      Chats::Engine.root.join("app/javascript/chats/thread_controller.js").to_s,
      stdin_data: <<~"JAVASCRIPT"
        const fs = require("fs")
        const assert = require("assert")

        let sourceText = fs.readFileSync(process.argv[2], "utf8")
        sourceText = sourceText
          .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
          // Catching up is chats/recovery's, tested on its own (recovery_test.rb).
          .replace('import { cancelStreamsFor, recoverMissedBroadcasts, renderStreamFrom } from "chats/recovery"',
                   "const cancelStreamsFor = () => {}, recoverMissedBroadcasts = () => () => {}, renderStreamFrom = () => Promise.resolve()")
          .replace("export default class extends Controller", "return class ThreadController extends Controller")

        // Timers we fire by hand, and every fetch the controller makes.
        let timers = []
        global.setTimeout = (callback) => { timers.push(callback); return timers.length }
        global.clearTimeout = () => {}
        const runTimers = () => { const due = timers; timers = []; due.forEach((callback) => callback()) }
        let posted = []
        global.fetch = (url, options) => { posted.push([options?.method, url]); return Promise.resolve() }
        global.document = { visibilityState: "visible", querySelector: () => null }

        const ThreadController = new Function(sourceText)()

        // The dock window's frame: the gate the thread finds with closest().
        function gate({ active = "true", minimized = false } = {}) {
          const attributes = new Set(minimized ? ["data-chats-minimized"] : [])
          return {
            dataset: { chatsActive: active },
            hasAttribute: (name) => attributes.has(name),
            minimize: () => attributes.add("data-chats-minimized"),
            expand: () => attributes.delete("data-chats-minimized")
          }
        }

        function thread(windowGate) {
          const controller = new ThreadController()
          controller.readUrlValue = "/messages/1/read"
          controller.hasScrollerTarget = true
          // A folded window's scroller with padding left: 16px tall, nothing
          // of the thread visible. Geometry says "on screen"; it isn't.
          controller.scrollerTarget = { clientHeight: 16, scrollHeight: 400, scrollTop: 0 }
          controller.scrollToBottom = () => {}
          controller.gate = windowGate
          return controller
        }

        // 1. The read was scheduled while the window was open; the viewer
        //    minimized it before the 700ms timer fired.
        let windowGate = gate()
        let controller = thread(windowGate)
        controller.queueRead()
        assert.strictEqual(timers.length, 1, "a read is scheduled while the window is open")
        windowGate.minimize()
        runTimers()
        assert.deepStrictEqual(posted, [], "no read posted for a minimized window")
        assert.strictEqual(controller.pendingRead, true, "it waits instead")

        //    Expanded again (the dock's ResizeObserver / activation calls this):
        windowGate.expand()
        controller.flushPendingRead()
        runTimers()
        assert.deepStrictEqual(posted, [["POST", "/messages/1/read"]], "the read happens once it is open again")

        // 2. Minimized from the start: a message arriving never schedules a post.
        posted = []
        controller = thread(gate({ minimized: true }))
        controller.queueRead()
        runTimers()
        assert.deepStrictEqual(posted, [])
        assert.strictEqual(controller.pendingRead, true)

        // 3. Popped open, not engaged: no read until the dock says so.
        windowGate = gate({ active: "false" })
        controller = thread(windowGate)
        controller.queueRead()
        runTimers()
        assert.deepStrictEqual(posted, [], "a window that opened by itself doesn't read")
        windowGate.dataset.chatsActive = "true"
        controller.flushPendingRead()
        runTimers()
        assert.deepStrictEqual(posted, [["POST", "/messages/1/read"]], "the viewer turned to it: now it reads")

        // 4. The thread page: no gate, reads as it always did.
        posted = []
        controller = thread(null)
        controller.queueRead()
        runTimers()
        assert.deepStrictEqual(posted, [["POST", "/messages/1/read"]])

        console.log("ok")
      JAVASCRIPT
    )

    assert status.success?, "node test failed\nSTDOUT:\n#{stdout}\nSTDERR:\n#{stderr}"
    assert_equal "ok", stdout.strip
  end

  private

  def node_available?
    system("node", "--version", out: File::NULL, err: File::NULL)
  end
end
