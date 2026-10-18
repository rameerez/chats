# frozen_string_literal: true

require "test_helper"
require_relative "support/node_script"

# What the unread badge and the dock do when chats/recovery says their
# streams may have missed something (in node; a recording stand-in for
# chats/recovery).
class BadgeAndDockCatchUpTest < ActiveSupport::TestCase
  include NodeScript

  def run_with_recovery(script)
    run_node(<<~JAVASCRIPT)
      browser.install()
      const watching = []
      const fetched = []
      const recovery = {
        recoverMissedBroadcasts(element, catchUp, options) {
          const watch = { element, catchUp, options, stopped: false }
          watching.push(watch)
          return () => { watch.stopped = true }
        },
        renderStreamFrom: (url) => fetched.push(url)
      }
      #{script}
    JAVASCRIPT
  end

  test "the badge watches its stream and asks GET /badge for every badge on the page" do
    run_with_recovery(<<~JAVASCRIPT)
      const Badge = loader.loadController("unread_badge_controller.js", { recovery })
      const badge = new Badge()
      badge.element = { tag: "span" }
      badge.urlValue = "/messages/badge"
      badge.connect()

      assert.strictEqual(watching.length, 1)
      assert.strictEqual(watching[0].element, badge.element)
      watching[0].catchUp()
      assert.deepStrictEqual(fetched, ["/messages/badge"])

      badge.disconnect()
      assert.strictEqual(watching[0].stopped, true)
    JAVASCRIPT
  end

  test "the dock watches its own stream only, and catches up its list and its badges" do
    run_with_recovery(<<~JAVASCRIPT)
      const Dock = loader.loadController("dock_controller.js", { recovery })
      const dock = new Dock()
      dock.element = {}
      dock.badgeUrlValue = "/messages/badge"
      dock.layout = dock.restore = dock.pageChanged = () => {}
      Object.defineProperty(dock, "windowTargets", { value: [] })
      global.window.matchMedia = () => ({ matches: false })
      global.window.visualViewport = null
      dock.connect()

      assert.strictEqual(watching.length, 1)
      assert.deepStrictEqual(watching[0].options, { sources: ":scope > turbo-cable-stream-source" })

      let listRefreshes = 0
      dock.refreshList = () => listRefreshes++
      watching[0].catchUp()
      assert.strictEqual(listRefreshes, 1)
      assert.deepStrictEqual(fetched, ["/messages/badge"])

      dock.releaseSheet = () => {}
      dock.disconnect()
      assert.strictEqual(watching[0].stopped, true)
    JAVASCRIPT
  end

  test "a dock list that is closed when it catches up reloads when it next opens; one never loaded loads fresh" do
    run_with_recovery(<<~JAVASCRIPT)
      const Dock = loader.loadController("dock_controller.js", { recovery })
      const dock = new Dock()
      let reloads = 0
      const list = { complete: true, hasAttribute: (name) => name === "complete" && list.complete, reload: () => reloads++ }
      Object.defineProperty(dock, "hasListTarget", { value: true })
      Object.defineProperty(dock, "listTarget", { value: list })
      Object.defineProperty(dock, "panelTarget", { value: { open: false } })

      dock.catchUp()
      assert.strictEqual(dock.listStale, true)
      assert.strictEqual(reloads, 0)

      list.complete = false
      dock.listStale = false
      dock.catchUp()
      assert.strictEqual(dock.listStale, false, "never loaded: it loads fresh when first shown")
    JAVASCRIPT
  end
end
