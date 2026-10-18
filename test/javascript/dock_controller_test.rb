# frozen_string_literal: true

require "test_helper"
require "open3"

# The dock controller's DECISIONS, run in node against plain fakes (no DOM,
# no Stimulus): when a live message may open a window, that the badge's
# signal is acted on once, how the cap picks what to close, and that a
# browser refusing localStorage never breaks the dock. The layout itself is
# CSS, verified in a browser.
class DockControllerTest < ActiveSupport::TestCase
  test "the dock's pop-up policy, signal handling, cap and storage" do
    skip "node is not available" unless node_available?

    stdout, stderr, status = Open3.capture3(
      "node",
      "-",
      Chats::Engine.root.join("app/javascript/chats/dock_controller.js").to_s,
      stdin_data: <<~"JAVASCRIPT"
        const fs = require("fs")
        const assert = require("assert")

        let sourceText = fs.readFileSync(process.argv[2], "utf8")
        sourceText = sourceText
          .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
          .replace("export default class extends Controller", "return class DockController extends Controller")

        global.window = { innerWidth: 1400, localStorage: null }
        const DockController = new Function(sourceText)()

        // --- fakes ---------------------------------------------------------

        let windows
        let removed

        function attributeSet(initial = []) {
          const attributes = new Set(initial)
          return {
            hasAttribute: (name) => attributes.has(name),
            removeAttribute: (name) => attributes.delete(name),
            setAttribute: (name) => attributes.add(name)
          }
        }

        function frame(id, { minimized = false } = {}) {
          const classes = new Set(["chats-window"])
          if (minimized) classes.add("chats-window--minimized")
          const node = {
            ...attributeSet(),
            dataset: { conversationId: id },
            offsetWidth: 320,
            classes,
            classList: {
              contains: (name) => classes.has(name),
              add: (name) => classes.add(name),
              remove: (name) => classes.delete(name),
              toggle: (name, on) => (on ? classes.add(name) : classes.delete(name))
            },
            querySelector: () => null,
            contains: () => false,
            remove() {
              windows.splice(windows.indexOf(node), 1)
              removed.push(id)
            }
          }
          return node
        }

        function dock({ open = [], compact = false, width = 1400 } = {}) {
          windows = open
          removed = []
          window.innerWidth = width

          const controller = new DockController()
          Object.defineProperty(controller, "windowTargets", { get: () => windows.slice() })
          controller.windowsValue = 3
          controller.storageKeyValue = "chats:dock:alice"
          controller.panelTarget = { offsetWidth: 288, open: false }
          controller.compact = compact
          controller.renderedOnPage = () => false
          controller.opened = []
          controller.openWindow = (id, options) => controller.opened.push([id, options])
          return controller
        }

        // --- the cap: windows beside the panel, never past the screen --------

        assert.strictEqual(dock().cap, 3)
        assert.strictEqual(dock({ width: 900 }).cap, 1, "a narrow screen holds fewer windows")
        assert.strictEqual(dock({ compact: true }).cap, 1, "a phone shows one")

        let controller = dock({ open: [frame("1"), frame("2"), frame("3")] })
        controller.windowsValue = 2
        const newest = windows[2]
        controller.enforceCap(newest)
        assert.deepStrictEqual(removed, ["1"], "the oldest window closes first")

        // --- a live message pops a window up ----------------------------------

        controller = dock({ open: [frame("1")] })
        controller.popUp("2")
        assert.deepStrictEqual(controller.opened, [["2", undefined]], "below the cap: open, expanded")

        controller = dock({ open: [frame("1"), frame("2", { minimized: true }), frame("3")] })
        controller.popUp("4")
        assert.deepStrictEqual(removed, ["2"], "full: it takes a minimized window's place")
        assert.deepStrictEqual(controller.opened, [["4", { minimized: true }]], "and arrives minimized")

        controller = dock({ open: [frame("1"), frame("2"), frame("3")] })
        controller.popUp("4")
        assert.deepStrictEqual(removed, [], "never closes a conversation somebody has open")
        assert.deepStrictEqual(controller.opened, [])

        controller = dock({ open: [frame("1", { minimized: true })] })
        controller.popUp("1")
        assert(windows[0].classes.has("chats-window--unread"), "an open, minimized window is marked instead")
        assert.deepStrictEqual(controller.opened, [])

        controller = dock({ compact: true })
        controller.popUp("1")
        assert.deepStrictEqual(controller.opened, [], "a phone never loses its screen to a message")

        controller = dock()
        controller.renderedOnPage = () => true
        controller.popUp("1")
        assert.deepStrictEqual(controller.opened, [], "the page already shows it")

        // --- the badge's signal is acted on once --------------------------------

        controller = dock()
        let refreshes = 0
        const popUps = []
        controller.refreshList = () => refreshes++
        controller.popUp = (id) => popUps.push(id)

        controller.badgeTargetConnected({ ...attributeSet(), dataset: {} })
        assert.strictEqual(refreshes, 0, "the server-rendered badge is not news")

        const badge = { ...attributeSet(["data-changed", "data-pop-up"]), dataset: { latestConversationId: "7" } }
        controller.badgeTargetConnected(badge)
        controller.badgeTargetConnected(badge) // a Turbo Drive visit reconnects the same node
        assert.strictEqual(refreshes, 1)
        assert.deepStrictEqual(popUps, ["7"])

        const readBadge = { ...attributeSet(["data-changed"]), dataset: {} }
        controller.badgeTargetConnected(readBadge)
        assert.strictEqual(refreshes, 2, "a read reloads the list")
        assert.deepStrictEqual(popUps, ["7"], "and opens nothing")

        // --- persistence: remembered, and never fatal ----------------------------

        const stored = {}
        window.localStorage = {
          getItem: (key) => (key in stored ? stored[key] : null),
          setItem: (key, value) => { stored[key] = value }
        }

        controller = dock({ open: [frame("1", { minimized: true }), frame("2")] })
        controller.save()
        assert.deepStrictEqual(JSON.parse(stored["chats:dock:alice"]),
                               [{ id: "1", minimized: true }, { id: "2", minimized: false }])

        controller = dock()
        controller.restore()
        assert.deepStrictEqual(controller.opened, [["1", { minimized: true }], ["2", { minimized: false }]])

        for (const corrupt of ["{", '"text"', "null", '[{"nope":1}]']) {
          stored["chats:dock:alice"] = corrupt
          controller = dock()
          controller.restore()
          assert.deepStrictEqual(controller.opened, [], `ignores ${corrupt}`)
        }

        window.localStorage = {
          getItem() { throw new Error("SecurityError") },
          setItem() { throw new Error("QuotaExceededError") }
        }
        controller = dock({ open: [frame("1")] })
        controller.restore()
        controller.save()
        assert.deepStrictEqual(controller.opened, [], "a refused localStorage only means forgetting")

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
