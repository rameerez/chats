# frozen_string_literal: true

require "test_helper"
require "open3"

# The dock controller's DECISIONS, run in node against plain fakes (no DOM,
# no Stimulus): how many windows fit, which one makes room (and that its
# draft survives), when a live message may open a window, that the signal
# is acted on once, what a reload brings back, and that a browser refusing
# localStorage never breaks the dock. The layout itself is CSS, verified in
# a browser.
class DockControllerTest < ActiveSupport::TestCase
  test "the dock's fit, eviction, pop-up policy, signal handling and memory" do
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

        const stored = {}
        let storage = {
          getItem: (key) => (key in stored ? stored[key] : null),
          setItem: (key, value) => { stored[key] = value },
          removeItem: (key) => { delete stored[key] }
        }
        global.window = { innerWidth: 1280, get localStorage() { return storage } }
        global.document = { activeElement: null }
        global.getComputedStyle = () => ({ getPropertyValue: () => "" })
        global.requestAnimationFrame = (callback) => callback()
        const DockController = new Function(sourceText)()

        // --- fakes ---------------------------------------------------------

        let windows
        let removed

        function attributes(initial = []) {
          const set = new Set(initial)
          return {
            hasAttribute: (name) => set.has(name),
            removeAttribute: (name) => set.delete(name),
            setAttribute: (name) => set.add(name)
          }
        }

        function frame(id, { minimized = false, usedAt = 0, active = "true", draft = null } = {}) {
          const classes = new Set(["chats-window"])
          if (minimized) classes.add("chats-window--minimized")
          const input = draft === null ? null : { value: draft, matches: () => true }
          const events = []
          const node = {
            ...attributes(),
            dataset: { conversationId: id, usedAt: String(usedAt), chatsActive: active },
            classes,
            events,
            classList: {
              contains: (name) => classes.has(name),
              add: (name) => classes.add(name),
              remove: (name) => classes.delete(name),
              toggle: (name, on) => (on ? classes.add(name) : classes.delete(name))
            },
            querySelector: (selector) => (selector === ".chats-composer__input" ? input : null),
            querySelectorAll: () => [],
            toggleAttribute: () => {},
            contains: (element) => element === node || (input && element === input),
            dispatchEvent: (event) => events.push(event.type),
            remove() {
              windows.splice(windows.indexOf(node), 1)
              removed.push(id)
            }
          }
          node.input = input
          return node
        }

        function dock({ open = [], compact = false, width = 1280 } = {}) {
          windows = open
          removed = []
          window.innerWidth = width
          document.activeElement = null

          const controller = new DockController()
          Object.defineProperty(controller, "windowTargets", { get: () => windows.slice() })
          controller.windowsValue = 3
          controller.messagerValue = "alice"
          controller.panelTarget = { offsetWidth: 288, open: false, querySelector: () => ({ focus() {} }) }
          controller.element = { hidden: false, contains: () => false }
          controller.compact = compact
          controller.renderedOnPage = () => false
          controller.markOpenRows = () => {}
          controller.syncSheet = () => {}
          controller.flash = () => {}
          controller.initialize()
          controller.opened = []
          controller.openWindow = (id, options) => {
            controller.opened.push([id, options])
            return frame(id)
          }
          return controller
        }

        // --- how many windows fit beside the panel ---------------------------

        assert.strictEqual(dock({ width: 1280 }).fit, 2, "two at 1280px")
        assert.strictEqual(dock({ width: 768 }).fit, 1, "one at 768px")
        assert.strictEqual(dock({ width: 1440 }).fit, 3, "three from 1344px")
        assert.strictEqual(dock({ width: 2560 }).fit, 3, "never more than windows:")
        assert.strictEqual(dock({ compact: true, width: 390 }).fit, 3, "a phone shows one at a time, keeps up to the cap")

        // --- making room: least recently used, never the focused one, drafts kept

        let controller = dock({
          open: [frame("1", { usedAt: 30, draft: "half a thought" }), frame("2", { usedAt: 10 }), frame("3", { usedAt: 20 })]
        })
        document.activeElement = windows[1].input || windows[1] // window 2 has the focus
        windows[1].contains = () => true
        assert.strictEqual(controller.makeRoom(null, { force: false }), false,
                           "only windows in use are left, and a pop-up closes none of them")
        assert.deepStrictEqual(removed, ["3"], "the one not in use went; the focused one and the drafted one stay")

        // Closed by the viewer, a window's unsent text is kept for next time.
        controller = dock({ open: [frame("1", { draft: "half a thought" })] })
        controller.closeWindow(windows[0])
        assert.deepStrictEqual(JSON.parse(stored["chats:draft:alice:1"]).text, "half a thought")
        assert.ok(controller.closed["1"], "and it won't pop open again for five minutes")

        controller = dock({ open: [frame("1")] }) // fit 1 at 768
        window.innerWidth = 768
        windows[0].contains = () => true
        document.activeElement = {}
        assert.strictEqual(controller.makeRoom(null, { force: false }), false, "a pop-up never closes the window in use")
        assert.deepStrictEqual(removed, [])

        // --- a window the viewer opens never closes one in use ------------------
        // At the one-window fit (768px): the focused window, or one holding
        // unsent text, is folded instead and stays; a window not in use goes.

        controller = dock({ width: 768, open: [frame("1")] })
        windows[0].contains = () => true
        document.activeElement = {}
        assert.strictEqual(controller.makeRoom(null, { force: true }), true)
        assert.deepStrictEqual(removed, [], "the window being typed in is never closed")
        assert(windows[0].classes.has("chats-window--minimized"), "it folds, beside the new one")
        assert(windows[0].classes.has("chats-window--squeezed"), "with the compact header a crowded row needs")
        controller.setMinimized(windows[0], false)
        assert(!windows[0].classes.has("chats-window--squeezed"), "and gets its full header back when expanded")

        controller = dock({ width: 768, open: [frame("1", { draft: "half a thought" })] })
        assert.strictEqual(controller.makeRoom(null, { force: true }), true)
        assert.deepStrictEqual(removed, [], "nor one holding unsent text")
        assert(windows[0].classes.has("chats-window--minimized"))

        controller = dock({ width: 768, open: [frame("1", { draft: "   " })] })
        assert.strictEqual(controller.makeRoom(null, { force: true }), true)
        assert.deepStrictEqual(removed, ["1"], "a window not in use makes room")

        controller = dock({ width: 768, open: [frame("1", { draft: "kept" }), frame("2", { usedAt: 1 })] })
        controller.makeRoom(null, { force: true })
        assert.deepStrictEqual(removed, ["2"], "the one not in use goes first, whatever its age")
        assert(windows[0].classes.has("chats-window--minimized"), "then the one in use folds: the new one needs the row")

        controller = dock({ width: 1280, open: [frame("1", { draft: "kept" }), frame("2", { usedAt: 1 })] })
        controller.makeRoom(null, { force: true })
        assert.deepStrictEqual(removed, ["2"])
        assert(!windows[0].classes.has("chats-window--minimized"), "with room for two, nothing in use needs folding")

        // --- the phone sheet inerts the page, never itself ----------------------
        // A host may render the dock inside a layout wrapper: every sibling
        // of the dock and of each ancestor is inerted, the ancestors are not.

        function node(name, children = []) {
          const element = { name, inert: false, children }
          children.forEach((child) => { child.parentElement = element })
          return element
        }
        const dockElement = node("dock")
        const main = node("main")
        const shell = node("shell", [main, dockElement])
        const header = node("header")
        const script = node("script")
        const body = node("body", [header, shell, script])
        global.document.body = body
        global.document.documentElement = { classList: { toggle() {}, remove() {} } }

        controller = dock({ compact: true, width: 390 })
        controller.element = Object.assign(dockElement, { hidden: false, contains: () => false })
        controller.panelTarget.open = true
        DockController.prototype.syncSheet.call(controller)
        assert.deepStrictEqual([header, shell, script, main, dockElement].map((n) => `${n.name}:${n.inert}`),
                               ["header:true", "shell:false", "script:true", "main:true", "dock:false"],
                               "the wrapper and the dock stay live; everything around them goes inert")

        controller.panelTarget.open = false
        DockController.prototype.syncSheet.call(controller)
        assert.deepStrictEqual([header, script, main].map((n) => n.inert), [false, false, false], "and back on close")

        // --- a live message pops a window up -----------------------------------

        controller = dock({ open: [frame("1")] })
        controller.popUp("2", 3)
        assert.deepStrictEqual(controller.opened, [["2", { active: false }]],
                               "below the fit: open, expanded, not engaged (it waits to be read)")

        controller = dock({ open: [frame("1", { minimized: true })] })
        controller.popUp("1", 2)
        assert(windows[0].classes.has("chats-window--unread"), "an open, minimized window shows it has news")
        assert.strictEqual(windows[0].dataset.unread, "2")
        assert.deepStrictEqual(controller.opened, [])

        controller = dock({ compact: true })
        controller.popUp("1", 1)
        assert.deepStrictEqual(controller.opened, [], "a phone never loses its screen to a message")

        controller = dock()
        controller.closed = { 7: Date.now() - 60_000 }
        controller.popUp("7", 1)
        assert.deepStrictEqual(controller.opened, [], "closed a minute ago: not now")
        controller.closed = { 7: Date.now() - 6 * 60_000 }
        controller.popUp("7", 1)
        assert.strictEqual(controller.opened.length, 1, "closed six minutes ago: it may come back")

        // --- engaging with a window lets it read --------------------------------

        controller = dock({ open: [frame("1", { active: "false" })] })
        windows[0].classes.add("chats-window--unread")
        controller.engage({ target: { closest: () => windows[0] } })
        assert.strictEqual(windows[0].dataset.chatsActive, "true")
        assert(!windows[0].classes.has("chats-window--unread"))
        assert.deepStrictEqual(windows[0].events, ["chats:activated"], "the thread reads what waited")

        controller = dock({ open: [frame("1", { active: "false", minimized: true })] })
        controller.engage({ target: { closest: () => windows[0] } })
        assert.strictEqual(windows[0].dataset.chatsActive, "false", "a minimized window never reads")

        // --- the signal is acted on once ------------------------------------------

        controller = dock()
        let refreshes = 0
        const popUps = []
        const announcements = []
        controller.refreshList = () => refreshes++
        controller.popUp = (id, unread) => popUps.push([id, unread])
        controller.announce = (id, name) => announcements.push([id, name])

        controller.signalTargetConnected({ ...attributes(), dataset: {} })
        assert.strictEqual(refreshes, 0, "the server-rendered signal is not news")

        const signal = {
          ...attributes(["data-changed", "data-notify"]),
          dataset: { conversationId: "7", unreadCount: "2", senderName: "Bob" }
        }
        controller.signalTargetConnected(signal)
        controller.signalTargetConnected(signal) // a Turbo Drive visit reconnects the same node
        assert.strictEqual(refreshes, 1)
        assert.deepStrictEqual(popUps, [["7", 2]])
        assert.deepStrictEqual(announcements, [["7", "Bob"]])

        controller.signalTargetConnected({ ...attributes(["data-changed"]), dataset: { conversationId: "7" } })
        assert.strictEqual(refreshes, 2, "a send or an edit reloads the list")
        assert.strictEqual(popUps.length, 1, "and opens nothing")

        controller.element.hidden = true
        controller.signalTargetConnected({ ...attributes(["data-changed", "data-notify"]), dataset: { conversationId: "8" } })
        assert.strictEqual(popUps.length, 1, "a hidden dock never pops up")

        // --- a repeated dock: true focuses the open window ------------------------

        controller = dock({ open: [frame("5", { draft: "keep me" })] })
        let shown = null
        controller.show = (target) => { shown = target }
        let prevented = false
        controller.beforeStreamRender({
          target: {
            getAttribute: (name) => ({ action: "append", target: "chats_dock_windows" })[name],
            templateContent: { querySelector: () => ({ dataset: { conversationId: "5" } }) }
          },
          preventDefault: () => { prevented = true }
        })
        assert(prevented, "the append that would reload it (and lose what's typed) never runs")
        assert.strictEqual(shown, windows[0])

        // --- memory: per viewer, up to the fit, never fatal ------------------------

        controller = dock({ open: [frame("1", { minimized: true, usedAt: 5 }), frame("2", { usedAt: 9 })] })
        controller.closed = { 9: Date.now() }
        controller.save()
        const saved = JSON.parse(stored["chats:dock:v1:alice"])
        assert.deepStrictEqual(saved.windows, [{ id: "1", minimized: true, usedAt: 5 }, { id: "2", minimized: false, usedAt: 9 }])
        assert.ok(saved.closed["9"])

        stored["chats:dock:v1:alice"] = JSON.stringify({
          panel: true,
          windows: [{ id: "1" }, { id: "2", minimized: true }, { id: "3" }]
        })
        controller = dock({ width: 1280 })
        controller.restore()
        assert.deepStrictEqual(controller.opened.map(([id, options]) => [id, options.active, options.minimized]),
                               [["2", false, true], ["3", false, false]],
                               "the newest that fit, not engaged until the viewer turns to them")
        assert.strictEqual(controller.panelTarget.open, true, "the dock's panel comes back")

        controller = dock({ compact: true, width: 390 })
        controller.restore()
        assert.strictEqual(controller.panelTarget.open, false, "the sheet always starts closed")

        assert.strictEqual(dock().draftKey("4"), "chats:draft:alice:4", "drafts are per viewer")

        for (const corrupt of ["{", '"text"', "null", '{"windows":"no"}', '{"windows":[{"nope":1}]}']) {
          stored["chats:dock:v1:alice"] = corrupt
          controller = dock()
          controller.restore()
          assert.deepStrictEqual(controller.opened, [], `ignores ${corrupt}`)
        }

        storage = {
          getItem() { throw new Error("SecurityError") },
          setItem() { throw new Error("QuotaExceededError") },
          removeItem() { throw new Error("SecurityError") }
        }
        controller = dock({ open: [frame("1", { draft: "x" })] })
        controller.restore()
        controller.save()
        controller.removeWindow(windows[0])
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
