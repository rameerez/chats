# frozen_string_literal: true

require "test_helper"
require "open3"

class RefreshInboxControllerTest < ActiveSupport::TestCase
  test "refreshes after a stream reconnect or long hidden interval" do
    skip "node is not available" unless node_available?

    stdout, stderr, status = Open3.capture3(
      "node",
      "-",
      Chats::Engine.root.join("app/javascript/chats/refresh_inbox_controller.js").to_s,
      stdin_data: <<~"JAVASCRIPT"
        const fs = require("fs")
        const assert = require("assert")

        let sourceText = fs.readFileSync(process.argv[2], "utf8")
        sourceText = sourceText
          .replace('import { Controller } from "@hotwired/stimulus"', 'class Controller { constructor() { this.element = null } }')
          .replace("export default class extends Controller", "return class RefreshInboxController extends Controller")

        let observer
        class FakeMutationObserver {
          constructor(callback) {
            this.callback = callback
            observer = this
            this.disconnected = false
          }

          observe(source, options) {
            this.source = source
            this.options = options
          }

          disconnect() {
            this.disconnected = true
          }

          trigger() {
            this.callback()
          }
        }

        function streamSourceElement() {
          const attributes = new Set()

          return {
            hasAttribute(name) {
              return attributes.has(name)
            },

            setAttribute(name) {
              attributes.add(name)
            },

            removeAttribute(name) {
              attributes.delete(name)
            }
          }
        }

        let visibilityHandler
        let now = 1_000_000
        let refreshCalls = []

        global.MutationObserver = FakeMutationObserver
        Date.now = () => now
        global.document = {
          baseURI: "https://example.test/messages",
          visibilityState: "visible",
          activeElement: null,
          addEventListener(name, handler) {
            if (name === "visibilitychange") visibilityHandler = handler
          },
          removeEventListener(name, handler) {
            if (name === "visibilitychange" && visibilityHandler === handler) visibilityHandler = null
          }
        }
        global.window = {
          Turbo: {
            session: {
              refresh(url) {
                refreshCalls.push(url)
              }
            }
          }
        }

        const RefreshInboxController = new Function(sourceText)()
        const source = streamSourceElement()
        const controller = new RefreshInboxController()
        controller.element = {
          querySelector(selector) {
            return selector === "turbo-cable-stream-source" ? source : null
          }
        }

        controller.connect()

        assert(observer, "expected MutationObserver to be installed")
        assert.deepStrictEqual(observer.options, { attributes: true, attributeFilter: ["connected"] })

        source.removeAttribute("connected")
        observer.trigger()
        source.setAttribute("connected", "")
        observer.trigger()
        assert.deepStrictEqual(refreshCalls, ["https://example.test/messages"])

        refreshCalls = []
        document.visibilityState = "hidden"
        visibilityHandler()
        now += 61_000
        document.visibilityState = "visible"
        visibilityHandler()
        assert.deepStrictEqual(refreshCalls, ["https://example.test/messages"])

        refreshCalls = []
        document.activeElement = {
          matches(selector) {
            return selector === "input, textarea, select"
          }
        }
        source.removeAttribute("connected")
        observer.trigger()
        source.setAttribute("connected", "")
        observer.trigger()
        assert.deepStrictEqual(refreshCalls, [])

        controller.disconnect()

        assert.strictEqual(observer.disconnected, true)
        assert.strictEqual(visibilityHandler, null)
      JAVASCRIPT
    )

    assert status.success?, "node smoke test failed\nSTDOUT:\n#{stdout}\nSTDERR:\n#{stderr}"
  end

  private

  def node_available?
    system("node", "--version", out: File::NULL, err: File::NULL)
  end
end
