# frozen_string_literal: true

require "test_helper"
require_relative "support/node_script"

# chats--refresh-inbox, in node against a fake page (support/browser.js):
# what it runs to catch up, how it reruns a refresh Turbo dropped mid-visit,
# and that a refresh never rewrites the field being typed in. When it
# catches up is chats/recovery's (recovery_test.rb).
class RefreshInboxControllerTest < ActiveSupport::TestCase
  include NodeScript

  def run_inbox(script)
    run_node(<<~JAVASCRIPT)
      const page = browser.install()
      const RefreshInbox = loader.loadController("refresh_inbox_controller.js")
      const source = page.streamSource()
      const controller = new RefreshInbox()
      controller.element = page.element({ sources: [source] })
      controller.connect()
      source.confirm()
      const refreshStream = () => page.documentEvents.dispatch("turbo:before-stream-render", { target: { getAttribute: (name) => (name === "action" ? "refresh" : null) } })
      #{script}
    JAVASCRIPT
  end

  test "catching up is a morphing, scroll-keeping page refresh of the page itself" do
    run_inbox(<<~JAVASCRIPT)
      source.drop()
      source.confirm()
      page.advance(250)
      assert.deepStrictEqual(page.refreshes, [{ url: "https://example.test/messages", options: { method: "morph", scroll: "preserve" } }])
    JAVASCRIPT
  end

  test "a refresh that arrives mid-visit, which Turbo would drop, runs once that visit completes" do
    run_inbox(<<~JAVASCRIPT)
      page.documentEvents.dispatch("turbo:visit")
      page.htmlAttributes.add("aria-busy")      // Turbo marks <html> busy for the visit
      refreshStream()
      refreshStream()
      page.htmlAttributes.delete("aria-busy")
      page.documentEvents.dispatch("turbo:load")
      assert.strictEqual(page.refreshes.length, 1, "two refreshes waiting are one")
      assert.deepStrictEqual(page.refreshes[0].options, { method: "morph", scroll: "preserve" })

      page.documentEvents.dispatch("turbo:load")
      assert.strictEqual(page.refreshes.length, 1, "and only once")
    JAVASCRIPT
  end

  test "a refresh with no visit in flight is Turbo's own to run" do
    run_inbox(<<~JAVASCRIPT)
      refreshStream()
      page.documentEvents.dispatch("turbo:visit")   // Turbo's refresh visit
      page.documentEvents.dispatch("turbo:load")
      assert.strictEqual(page.refreshes.length, 0)
    JAVASCRIPT
  end

  test "a visit that starts after the refresh arrived already fetches what it was about" do
    run_inbox(<<~JAVASCRIPT)
      page.htmlAttributes.add("aria-busy")
      refreshStream()
      page.documentEvents.dispatch("turbo:visit")   // a new visit: its request comes after the refresh
      page.documentEvents.dispatch("turbo:load")
      assert.strictEqual(page.refreshes.length, 0)
    JAVASCRIPT
  end

  test "an inbox the visit took away refreshes nothing" do
    run_inbox(<<~JAVASCRIPT)
      page.htmlAttributes.add("aria-busy")
      refreshStream()
      controller.element.isConnected = false
      page.documentEvents.dispatch("turbo:load")
      assert.strictEqual(page.refreshes.length, 0)
    JAVASCRIPT
  end

  test "other streams arriving mid-visit are not refreshes" do
    run_inbox(<<~JAVASCRIPT)
      page.htmlAttributes.add("aria-busy")
      page.documentEvents.dispatch("turbo:before-stream-render", { target: { getAttribute: () => "replace" } })
      page.documentEvents.dispatch("turbo:load")
      assert.strictEqual(page.refreshes.length, 0)
    JAVASCRIPT
  end

  test "a refresh never rewrites the value of the field being typed in, and nothing else is held back" do
    run_inbox(<<~JAVASCRIPT)
      const search = { localName: "input" }
      document.activeElement = search
      const morph = (target, attributeName) =>
        page.documentEvents.dispatch("turbo:before-morph-attribute", { target, detail: { attributeName, mutationType: "update" } })

      assert.strictEqual(morph(search, "value").defaultPrevented, true)
      assert.strictEqual(morph(search, "placeholder").defaultPrevented, false)
      assert.strictEqual(morph({ localName: "input" }, "value").defaultPrevented, false, "a field nobody is typing in follows the page")
    JAVASCRIPT
  end

  test "disconnecting stops catching up and removes every listener of its own" do
    run_inbox(<<~JAVASCRIPT)
      controller.disconnect()
      for (const name of ["turbo:visit", "turbo:before-stream-render", "visibilitychange"]) {
        assert.strictEqual(page.documentEvents.count(name), 0, name)
      }
      // What stays is chats/recovery's, page-wide and installed once: the
      // stream guards and the watch on page renders.
      assert.strictEqual(page.documentEvents.count("turbo:before-morph-attribute"), 1)
      assert.strictEqual(page.documentEvents.count("turbo:render"), 1)

      source.confirm()
      page.advance(10_000)
      assert.strictEqual(page.refreshes.length, 0)
    JAVASCRIPT
  end
end
