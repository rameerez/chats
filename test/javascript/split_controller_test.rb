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
      const queries = []
      global.window = { matchMedia: (query) => { queries.push(query); return media } }
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
        const li = { classes: new Set(), classList: { toggle(name, on) { on ? li.classes.add(name) : li.classes.delete(name) } } }
        const link = element({ href, "data-turbo-frame": "chats_conversation" })
        link.closest = (selector) => (selector === ".chats-row" ? li : null)
        link.row = li
        return link
      }

      const frame = element({ id: "chats_conversation", disabled: "disabled" })
      frame.id = "chats_conversation"
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

      frame.setAttribute("src", "https://example.test/messages/2")
      controller.opened(event(frame))

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
end
