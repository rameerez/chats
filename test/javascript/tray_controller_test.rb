# frozen_string_literal: true

require "test_helper"
require "open3"

# The tray controller's DECISIONS (chats--tray, 0.7.0), run in node against
# plain fakes, with the real chats/sheet inlined: one item open at a time and
# what it tells the dock, the read gate it keeps for a thread inside an item,
# Escape, what a reload brings back (on a desk only), the badge that reloads
# what follows it, an item yielding a thread the page shows, the sheet's
# inert held by owner, and a browser refusing localStorage. The layout is
# CSS, measured in Chrome (test/system/tray_layout_test.rb).
class TrayControllerTest < ActiveSupport::TestCase
  test "the tray's one-open rule, read gate, keyboard, memory, badges, yielding and sheet" do
    skip "node is not available" unless node_available?

    stdout, stderr, status = Open3.capture3(
      "node",
      "-",
      Chats::Engine.root.join("app/javascript/chats/tray_controller.js").to_s,
      Chats::Engine.root.join("app/javascript/chats/sheet.js").to_s,
      stdin_data: <<~JAVASCRIPT
        const fs = require("fs")
        const assert = require("assert")

        const sheet = fs.readFileSync(process.argv[3], "utf8").replace(/^export /gm, "")
        const asked = []
        let sourceText = fs.readFileSync(process.argv[2], "utf8")
          .replace('import { Controller } from "@hotwired/stimulus"',
                   "class Controller { dispatch(name, options) { this.dispatched.push([name, options.detail.key]) } }")
          .replace('import { recoverMissedBroadcasts, renderStreamFrom } from "chats/recovery"',
                   "const recoverMissedBroadcasts = () => () => {}, renderStreamFrom = (url) => asked.push(url)")
          .replace('import { around, fitViewport, holdInert, lockScroll, releaseInert } from "chats/sheet"', sheet)
          .replace("export default class extends Controller", "const TrayController = class extends Controller")
        // The controller and the sheet it shares with the dock, from one module scope.
        sourceText += "\\nreturn { TrayController, holdInert, releaseInert, lockScroll }"

        const stored = {}
        let storage = {
          getItem: (key) => (key in stored ? stored[key] : null),
          setItem: (key, value) => { stored[key] = value },
          removeItem: (key) => { delete stored[key] }
        }
        let lockClass = false
        global.window = {
          innerWidth: 1280,
          location: { href: "https://app.test/players", origin: "https://app.test" },
          get localStorage() { return storage }
        }
        global.getComputedStyle = () => ({ getPropertyValue: () => "" })
        const consoleErrors = []
        console.error = (message) => consoleErrors.push(message)
        global.document = {
          activeElement: null,
          documentElement: { classList: { toggle: (name, on) => { if (name === "chats-dock-sheet-open") lockClass = on } } },
          querySelectorAll: () => []
        }
        let timers = []
        global.setTimeout = (callback) => { timers.push(callback); return timers.length }
        global.clearTimeout = () => { timers = [] }
        const runTimers = () => { const pending = timers; timers = []; pending.forEach((callback) => callback()) }
        global.CustomEvent = class { constructor(type) { this.type = type } }
        const { TrayController, holdInert, releaseInert, lockScroll } = new Function("asked", sourceText)(asked)

        // --- fakes -----------------------------------------------------------

        function node(name, children = []) {
          const element = { name, inert: false, children }
          children.forEach((child) => { child.parentElement = element })
          return element
        }

        function item(key, { open = false, inside = [] } = {}) {
          const attributes = new Set()
          const events = []
          const summary = { focused: false, focus() { this.focused = true } }
          const element = node(`item:${key}`)
          Object.assign(element, {
            open,
            dataset: { chatsTrayKey: key, chatsTrayBadgeUrl: `/${key}/badge` },
            events,
            summary,
            inside,
            offsetWidth: 120,
            classes: new Set(),
            classList: {
              contains: (name) => element.classes.has(name),
              toggle: (name, on) => (on ? element.classes.add(name) : element.classes.delete(name)),
              add: (name) => element.classes.add(name)
            },
            styles: {},
            style: { setProperty: (name, value) => { element.styles[name] = value } },
            hasAttribute: (name) => attributes.has(name),
            toggleAttribute: (name, on) => (on ? attributes.add(name) : attributes.delete(name)),
            dispatchEvent: (event) => events.push(event.type),
            querySelector: (selector) => (selector === "summary" ? summary : null),
            querySelectorAll: (selector) => inside.filter((child) => child.matches(selector)),
            contains: (other) => other === element || inside.includes(other) || inside.some((child) => child.frame === other)

          })
          inside.forEach((child) => { child.closest = (selector) => (selector === "turbo-frame" ? child.frame : element) })
          return element
        }

        function tray(items, { compact = false } = {}) {
          const controller = new TrayController()
          controller.dispatched = []
          Object.defineProperty(controller, "itemTargets", { get: () => items })
          controller.ownerValue = "alice"
          controller.element = { querySelector: () => null, closest: () => null }
          controller.corner = null
          controller.compact = compact
          controller.initialize()
          items.forEach((each) => controller.itemTargetConnected(each))
          return controller
        }

        // --- the read gate a thread inside an item obeys ------------------------

        let help = item("help")
        let other = item("feedback", { open: true })
        let controller = tray([help, other])
        assert.strictEqual(help.dataset.chatsActive, "true", "an item is a gate, as a dock window is")
        assert(help.hasAttribute("data-chats-minimized"), "closed: a thread inside never reads")
        assert(!other.hasAttribute("data-chats-minimized"), "open: it may")

        // --- one open at a time, and the dock told -----------------------------

        help.open = true
        controller.toggled({ target: help })
        assert.strictEqual(other.open, false, "opening one closes the other")
        assert.deepStrictEqual(controller.dispatched, [["open", "help"]], "chats--tray:open, for the dock's panel")
        assert.deepStrictEqual(help.events, ["chats:activated"], "a read that waited for the item happens now")
        assert(!help.hasAttribute("data-chats-minimized"))
        assert.strictEqual(JSON.parse(stored["chats:tray:v1:alice"]).open, "help", "remembered on a desk")

        help.open = false
        controller.toggled({ target: help })
        assert(help.hasAttribute("data-chats-minimized"))
        assert.deepStrictEqual(controller.dispatched.at(-1), ["close", "help"])
        assert.strictEqual(JSON.parse(stored["chats:tray:v1:alice"]).open, null)

        controller.toggled({ target: { open: true } })
        assert.strictEqual(controller.dispatched.length, 2, "a toggle that isn't an item's is ignored")

        // --- Escape --------------------------------------------------------------

        help = item("help", { open: true })
        controller = tray([help])
        let prevented = false
        const escape = (target = { closest: () => null }) => ({
          key: "Escape", defaultPrevented: false, target, preventDefault() { prevented = true }
        })
        controller.element.querySelector = () => ({ hidden: false }) // the thread's popup is up
        controller.keydown(escape())
        assert.strictEqual(help.open, true, "the thread's own popup closes first")
        controller.element.querySelector = () => null
        controller.keydown(escape())
        assert.strictEqual(help.open, false, "then Escape closes the item")
        assert(help.summary.focused, "and the focus goes back to its tab")
        assert(prevented, "the dock, outside it, doesn't act on the same Escape")

        // --- memory: a desk's choice, never a phone's ----------------------------

        stored["chats:tray:v1:alice"] = JSON.stringify({ open: "help" })
        help = item("help")
        tray([help]).restore()
        assert.strictEqual(help.open, true, "a reload brings back the open item")

        help = item("help")
        tray([help], { compact: true }).restore()
        assert.strictEqual(help.open, false, "a sheet always starts closed")

        help = item("help", { open: true })
        controller = tray([help], { compact: true })
        controller.save()
        assert.strictEqual(JSON.parse(stored["chats:tray:v1:alice"]).open, "help", "a phone keeps the desk's choice")

        for (const corrupt of ["{", "null", '"help"', '{"open":4}', '{"open":"gone"}']) {
          stored["chats:tray:v1:alice"] = corrupt
          help = item("help")
          tray([help]).restore()
          assert.strictEqual(help.open, false, `ignores ${corrupt}`)
        }

        // --- badges: what follows them reloads ------------------------------------

        let reloaded = 0
        const frame = { reload: () => { reloaded += 1 } }
        const marker = { matches: (selector) => selector === "[data-chats-tray-refresh]", frame }
        help = item("help", { inside: [marker] })
        controller = tray([help])
        controller.flash = () => {}
        const badge = (count) => ({ dataset: { count: String(count) }, closest: () => help, classList: { add() {}, remove() {} } })

        controller.badgeTargetConnected(badge(1))
        runTimers()
        assert.strictEqual(reloaded, 0, "the first badge is where it starts")
        controller.badgeTargetConnected(badge(2))
        runTimers()
        assert.strictEqual(reloaded, 0, "closed: nothing reloads yet…")
        help.open = true
        controller.toggled({ target: help })
        runTimers()
        assert.strictEqual(reloaded, 1, "…it reloads when the item opens")
        controller.badgeTargetConnected(badge(2))
        runTimers()
        assert.strictEqual(reloaded, 1, "the same count again moves nothing")
        controller.badgeTargetConnected(badge(0))
        runTimers()
        assert.strictEqual(reloaded, 2, "open: a count that moved reloads it now")

        controller.catchUp()
        assert.deepStrictEqual(asked, ["https://app.test/help/badge"], "a missed badge is asked again from the item's badge-url")

        // …from this site only: what comes back is applied to the page.
        asked.length = 0
        help.dataset.chatsTrayBadgeUrl = "https://evil.test/badge"
        controller.catchUp()
        help.dataset.chatsTrayBadgeUrl = "//evil.test/badge"
        controller.catchUp()
        assert.deepStrictEqual(asked, [], "a badge URL on another origin is never fetched")
        assert.strictEqual(consoleErrors.length, 2, "and the console says so")
        help.dataset.chatsTrayBadgeUrl = "/help/badge"

        // --- room: as wide as the corner leaves it, else the sheet ------------------

        const besideIt = item("feedback")
        const opening = item("help", { open: true })
        controller = tray([besideIt, opening])
        window.innerWidth = 1280
        controller.fit(opening)
        assert.strictEqual(opening.styles["--chats-tray-room"], "1120px", "the screen less the insets and the other tab")
        assert(!opening.classes.has("chats-tray__item--sheet"))
        window.innerWidth = 450
        controller.fit(opening)
        assert(!opening.classes.has("chats-tray__item--sheet"), "290px is room enough (--chats-tray-min-width: 280px)")
        window.innerWidth = 400
        controller.fit(opening)
        assert(opening.classes.has("chats-tray__item--sheet"), "240px is not: it opens as the sheet")
        window.innerWidth = 1280
        controller.fit(opening)
        assert(!opening.classes.has("chats-tray__item--sheet"), "and back in the corner when the screen widens")
        controller.save()
        assert.strictEqual(JSON.parse(stored["chats:tray:v1:alice"]).open, "help")
        opening.classes.add("chats-tray__item--sheet")
        controller.save()
        assert.strictEqual(JSON.parse(stored["chats:tray:v1:alice"]).open, null, "an item open as a desk's sheet isn't remembered")

        // --- never twice: an item yields a thread the page shows -------------------

        const home = { matches: (selector) => selector === "turbo-frame[data-chats-tray-home]",
                       dataset: { chatsTrayHome: "/support" }, src: "/support/tickets/T-1",
                       replaceChildren() { this.emptied = true } }
        const history = { matches: (selector) => selector === ".chats-thread__scroll[id]", id: "history_conversation_7" }
        help = item("help", { open: true, inside: [home, history] })
        controller = tray([help])
        const onPage = { id: "history_conversation_7" }
        global.window.CSS = { escape: (value) => value }
        global.document.querySelectorAll = (selector) => (selector === '[id="history_conversation_7"]' ? [history] : [])
        controller.yieldDuplicates()
        assert.strictEqual(home.src, "/support/tickets/T-1", "alone on the page: it stays")
        global.document.querySelectorAll = (selector) => (selector === '[id="history_conversation_7"]' ? [history, onPage] : [])
        controller.yieldDuplicates()
        assert.strictEqual(home.src, "/support", "the page shows it too: the item goes back home")
        assert(home.emptied, "at once: the ids exist once even before home arrives")
        global.document.querySelectorAll = () => []

        // --- on its own: hidden where the dock would be -----------------------------

        help = item("help", { open: true })
        controller = tray([help])
        controller.corner = { hidden: false, contains: () => false }
        global.document.querySelectorAll = (selector) => (selector === "[data-chats-dock-hide]" ? [{}] : [])
        controller.pageChanged()
        assert.strictEqual(controller.corner.hidden, true, "a page carrying data-chats-dock-hide")
        assert.strictEqual(help.open, false, "and nothing stays open behind it")
        global.document.querySelectorAll = () => []
        controller.pageChanged()
        assert.strictEqual(controller.corner.hidden, false)

        // --- the sheet: the page inert while an item is open, held by owner ----------

        const page = node("page")
        const dockPanel = node("panel")
        help = item("help", { open: true })
        const trayElement = node("tray", [help])
        const dockElement = node("dock", [dockPanel, trayElement])
        const body = node("body", [page, dockElement])
        global.document.body = body

        controller = tray([help], { compact: true })
        controller.syncSheet()
        assert.deepStrictEqual([page, dockPanel, dockElement, trayElement].map((n) => `${n.name}:${n.inert}`),
                               ["page:true", "panel:true", "dock:false", "tray:false"],
                               "everything around the item, inside the dock too; never its own ancestors")
        assert.strictEqual(lockClass, true, "the page doesn't scroll")

        // The dock's sheet holds the same page: one releasing keeps the other's.
        holdInert("dock", [page])
        lockScroll("dock", true)
        help.open = false
        controller.syncSheet()
        assert.strictEqual(page.inert, true, "still held by the dock")
        assert.strictEqual(dockPanel.inert, false, "what only the tray held is free")
        assert.strictEqual(lockClass, true, "and the page still locked")
        releaseInert("dock")
        lockScroll("dock", false)
        assert.strictEqual(page.inert, false)
        assert.strictEqual(lockClass, false)

        const hostsOwn = node("modal")
        hostsOwn.inert = true
        holdInert("tray", [hostsOwn])
        releaseInert("tray")
        assert.strictEqual(hostsOwn.inert, true, "a node the host made inert is never released by a sheet")

        controller = tray([item("help", { open: true })])
        controller.syncSheet()
        assert.strictEqual(page.inert, false, "on a desk an open item is no sheet")

        // --- a visit reconciles the carried tray with the new page's items, by key -----

        const keyed = (key) => ({ dataset: { chatsTrayKey: key }, toggleAttribute() {}, querySelector: () => null, removed: false, remove() { this.removed = true } })
        const kept = keyed("support")
        const gone = keyed("feedback")
        let appended = []
        controller = tray([kept, gone])
        controller.element = { id: "chats_tray_items_alice", append: (node) => appended.push(node), closest: () => null }
        const refreshed = []
        controller.refreshItem = (old, fresh) => refreshed.push([old.dataset.chatsTrayKey, fresh.dataset.chatsTrayKey])
        global.document.importNode = (node) => ({ imported: node.dataset.chatsTrayKey })
        const newPage = (keys) => ({
          querySelector: (selector) => (selector === '[id="chats_tray_items_alice"]'
            ? { querySelectorAll: () => keys.map((key) => ({ dataset: { chatsTrayKey: key } })) } : null)
        })
        controller.reconcile({ detail: { newBody: newPage(["support", "feedback"]) } })
        assert.deepStrictEqual(appended, [], "the same items: nothing moves")
        assert.deepStrictEqual(refreshed, [["support", "support"], ["feedback", "feedback"]],
                               "but each takes the new page's version of itself (refreshItem, measured in Chrome)")
        controller.reconcile({ detail: { newBody: newPage(["changelog", "support"]) } })
        assert(gone.removed, "an item the new page doesn't render goes")
        assert.deepStrictEqual(appended.map((node) => node.imported || node.dataset.chatsTrayKey), ["changelog", "support"],
                               "a new one comes in, the one still there is kept as it is, in the page's order")
        controller.reconcile({ detail: { newBody: { querySelector: () => null } } })

        // --- a browser refusing storage only forgets ----------------------------------

        storage = {
          getItem() { throw new Error("SecurityError") },
          setItem() { throw new Error("QuotaExceededError") },
          removeItem() { throw new Error("SecurityError") }
        }
        help = item("help")
        controller = tray([help])
        controller.restore()
        help.open = true
        controller.toggled({ target: help })
        assert.strictEqual(help.open, true)

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
