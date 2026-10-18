# frozen_string_literal: true

require "test_helper"
require_relative "support/node_script"

# chats--split, in node against a tiny fake page: the conversation frame is
# enabled only while the screen is wide, a refresh's morph can't disable it
# again, nothing prefetches a pane a narrow screen would render as a page,
# and the row the pane opens becomes the current one. The layout itself is
# chats.css's (test/system/split_inbox_test.rb measures it in Chrome).
class SplitControllerTest < ActiveSupport::TestCase
  include NodeScript

  def run_split(script)
    run_node(<<~JAVASCRIPT)
      // One media query, its width under the test's control.
      const media = { matches: true, listeners: [],
                      addEventListener(type, fn) { this.listeners.push(fn) },
                      removeEventListener(type, fn) { this.listeners = this.listeners.filter((l) => l !== fn) } }
      const touch = { matches: false }
      const queries = []
      global.window = { matchMedia: (query) => { queries.push(query); return query === "(pointer: coarse)" ? touch : media } }
      global.document = { baseURI: "https://example.test/messages" }
      const resize = (wide) => { media.matches = wide; media.listeners.forEach((fn) => fn()) }

      const element = (attributes = {}) => ({
        attributes: new Map(Object.entries(attributes)),
        hasAttribute(name) { return this.attributes.has(name) },
        getAttribute(name) { return this.attributes.has(name) ? this.attributes.get(name) : null },
        setAttribute(name, value) { this.attributes.set(name, String(value)) },
        removeAttribute(name) { this.attributes.delete(name) },
        toggleAttribute(name, force) { force ? this.attributes.set(name, "") : this.attributes.delete(name); return force }
      })
      const row = (href) => {
        const badge = { removed: false, remove() { this.removed = true } }
        const li = { classes: new Set(["chats-row--unread"]), badge,
                     classList: { toggle(name, on) { on ? li.classes.add(name) : li.classes.delete(name) },
                                  remove(name) { li.classes.delete(name) } },
                     querySelector: (selector) => (selector === ".chats-row__bottom .chats-badge" && !badge.removed ? badge : null) }
        const link = element({ href, "data-turbo-frame": "chats_conversation" })
        link.closest = (selector) => (selector === ".chats-row" ? li : null)
        link.row = li
        return link
      }

      // What the pane holds once a row opened it: its title and its composer.
      const focused = []
      const focusable = (name) => ({ name, focus(options) { focused.push([name, options]) } })
      const composer = focusable("composer")
      const title = focusable("title")
      const pane = { getAttribute: (name) => (name === "aria-labelledby" ? "title_conversation_2" : null),
                     querySelector: (selector) => ({ ".chats-composer__input": pane.composer,
                                                     '[id="title_conversation_2"]': title })[selector] || null,
                     composer, dataset: { path: "/messages/2", read: "false" } }
      const frame = element({ id: "chats_conversation", disabled: "disabled" })
      frame.id = "chats_conversation"
      frame.pane = null
      frame.querySelector = (selector) => (selector === ".chats-split__pane" ? frame.pane : null)
      const open = (src) => { frame.setAttribute("src", src); frame.pane = pane; controller.opened(event(frame)) }
      const links = [row("/messages/1"), row("/messages/2")]
      const list = { querySelectorAll: (selector) => (selector === 'a[data-turbo-frame="chats_conversation"]' ? links : []) }

      const Split = loader.loadController("split_controller.js")
      const controller = new Split()
      Object.assign(controller, { hasFrameTarget: true, frameTarget: frame, hasListTarget: true, listTarget: list })
      const event = (target, detail = {}) => ({ target, detail, prevented: false, preventDefault() { this.prevented = true } })
      #{script}
    JAVASCRIPT
  end

  test "the frame is enabled on a wide screen and disabled on a narrow one, as the screen changes" do
    run_split(<<~JAVASCRIPT)
      controller.connect()
      assert.deepStrictEqual(queries, ["(min-width: 700px)"], "chats.css's breakpoint")
      assert.strictEqual(frame.hasAttribute("disabled"), false, "wide: rows open in the pane")

      resize(false)
      assert.strictEqual(frame.hasAttribute("disabled"), true, "narrow: rows open the page")
      resize(true)
      assert.strictEqual(frame.hasAttribute("disabled"), false)

      controller.disconnect()
      resize(false)
      assert.strictEqual(frame.hasAttribute("disabled"), false, "a gone controller listens to nothing")
    JAVASCRIPT
  end

  test "starts disabled on a narrow screen, as the server renders it" do
    run_split(<<~JAVASCRIPT)
      media.matches = false
      controller.connect()
      assert.strictEqual(frame.hasAttribute("disabled"), true)
    JAVASCRIPT
  end

  test "a refresh's morph never changes the frame's disabled, and nothing else of it or of the page is kept" do
    run_split(<<~JAVASCRIPT)
      controller.connect()
      const disabled = event(frame, { attributeName: "disabled" })
      controller.keepEnabled(disabled)
      assert.strictEqual(disabled.prevented, true)

      const src = event(frame, { attributeName: "src" })
      controller.keepEnabled(src)
      assert.strictEqual(src.prevented, false)

      const elsewhere = event(element(), { attributeName: "disabled" })
      controller.keepEnabled(elsewhere)
      assert.strictEqual(elsewhere.prevented, false, "a host's own disabled field morphs as usual")
    JAVASCRIPT
  end

  test "no hover prefetch of a row while the frame is disabled; prefetch as usual while it is enabled" do
    run_split(<<~JAVASCRIPT)
      media.matches = false
      controller.connect()
      const narrow = event(links[0])
      controller.prefetch(narrow)
      assert.strictEqual(narrow.prevented, true, "Turbo would ask for the pane alone, then render it as the page")

      const other = event(element({ href: "/elsewhere" }))
      controller.prefetch(other)
      assert.strictEqual(other.prevented, false, "a link that names no frame prefetches as usual")

      resize(true)
      const wide = event(links[0])
      controller.prefetch(wide)
      assert.strictEqual(wide.prevented, false)
    JAVASCRIPT
  end

  test "the row the pane opened becomes the current one, and the one before it stops being" do
    run_split(<<~JAVASCRIPT)
      controller.connect()
      links[0].setAttribute("aria-current", "page")
      links[0].row.classes.add("chats-row--current")

      open("https://example.test/messages/2?with=abc") // the list's filter rides along; the row is the path

      assert.strictEqual(links[0].getAttribute("aria-current"), null)
      assert.strictEqual(links[0].row.classes.has("chats-row--current"), false)
      assert.strictEqual(links[1].getAttribute("aria-current"), "page")
      assert.strictEqual(links[1].row.classes.has("chats-row--current"), true)

      // A frame inside the pane (an older page of messages) is not the pane.
      links[1].removeAttribute("aria-current")
      controller.opened(event(element({ src: "/messages/1?before=9" })))
      assert.strictEqual(links[0].getAttribute("aria-current"), null)
      assert.strictEqual(links[1].getAttribute("aria-current"), null)
    JAVASCRIPT
  end

  test "a pane the server read clears its row's unread count at once; one it didn't leaves it" do
    run_split(<<~JAVASCRIPT)
      controller.connect()
      open("/messages/2")
      assert.strictEqual(links[1].row.badge.removed, false, "rendered unread: its thread reads it, then says so")
      assert.ok(links[1].row.classes.has("chats-row--unread"))

      pane.dataset.read = "true"
      open("/messages/2")
      assert.strictEqual(links[1].row.badge.removed, true)
      assert.strictEqual(links[1].row.classes.has("chats-row--unread"), false)
      assert.strictEqual(links[0].row.badge.removed, false, "only its own row")
      assert.ok(links[0].row.classes.has("chats-row--unread"))
    JAVASCRIPT
  end

  test "the tab takes the title the pane carries; a pane without one leaves the tab's" do
    run_split(<<~JAVASCRIPT)
      document.title = "Carol · Messages"
      controller.connect()
      open("/messages/2")
      assert.strictEqual(document.title, "Carol · Messages")

      pane.dataset.title = "Bob · Messages"
      open("/messages/2")
      assert.strictEqual(document.title, "Bob · Messages")
    JAVASCRIPT
  end

  test "a thread that reads on screen clears its row" do
    run_split(<<~JAVASCRIPT)
      controller.connect()
      open("/messages/2")
      controller.threadRead({ target: { closest: (selector) => (selector === ".chats-split__pane" ? pane : null) } })
      assert.strictEqual(links[1].row.badge.removed, true)
      assert.strictEqual(links[0].row.badge.removed, false)

      controller.threadRead({ target: { closest: () => null } }) // a dock window's thread: none of the list's business
      assert.strictEqual(links[0].row.badge.removed, false)
    JAVASCRIPT
  end

  test "the viewer is taken into the conversation the row opened: its composer, ready to reply" do
    run_split(<<~JAVASCRIPT)
      controller.connect()
      open("/messages/2")
      assert.deepStrictEqual(focused, [["composer", { preventScroll: true }]])
    JAVASCRIPT
  end

  test "on a touch screen, the conversation's title: the keyboard stays down until the viewer asks for it" do
    run_split(<<~JAVASCRIPT)
      touch.matches = true
      controller.connect()
      open("/messages/2")
      assert.deepStrictEqual(focused.map(([name]) => name), ["title"])
    JAVASCRIPT
  end

  test "the title too when there is nothing to write in (a locked conversation)" do
    run_split(<<~JAVASCRIPT)
      pane.composer = null
      controller.connect()
      open("/messages/2")
      assert.deepStrictEqual(focused.map(([name]) => name), ["title"])
    JAVASCRIPT
  end

  test "a load that brought no pane (a 404 page Turbo visits instead) moves nothing" do
    run_split(<<~JAVASCRIPT)
      controller.connect()
      frame.setAttribute("src", "/messages/2")
      controller.opened(event(frame))
      assert.deepStrictEqual(focused, [])
    JAVASCRIPT
  end
end
