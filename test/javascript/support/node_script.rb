# frozen_string_literal: true

require "open3"

# Runs a node script against the engine's JavaScript, with `loader`
# (loader.js: the engine's modules) and `browser` (browser.js: a fake page,
# clock and Action Cable) in scope, and fails the test with node's output when
# an assertion in it fails. Skips where node isn't installed.
module NodeScript
  LOADER = File.expand_path("loader.js", __dir__)
  BROWSER = File.expand_path("browser.js", __dir__)

  def run_node(script)
    skip "node is not available" unless system("node", "--version", out: File::NULL, err: File::NULL)

    stdout, stderr, status = Open3.capture3(
      "node", "-", LOADER, BROWSER,
      stdin_data: <<~JAVASCRIPT
        const assert = require("assert")
        const loader = require(process.argv[2])
        const browser = require(process.argv[3])
        #{script}
      JAVASCRIPT
    )
    assert status.success?, "node script failed\nSTDOUT:\n#{stdout}\nSTDERR:\n#{stderr}"
  end
end
