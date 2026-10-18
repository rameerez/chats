// Loads the engine's ES modules into plain node, no bundler and no DOM: the
// imports are swapped for what the test hands in, and everything else runs
// against whatever globals (document, window, MutationObserver, timers) the
// test has set up before loading.
const fs = require("fs")
const path = require("path")

const root = path.resolve(__dirname, "../../../app/javascript/chats")
const read = (name) => fs.readFileSync(path.join(root, name), "utf8")

// chats/recovery's exports.
function loadRecovery() {
  const source = read("recovery.js").replace(/^export /gm, "")
  return new Function(`${source}\nreturn { afterRendering, cancelStreamsFor, recoverMissedBroadcasts, renderStreamFrom }`)()
}

// A controller class, extending +Controller+ (a bare class by default),
// importing from +recovery+ (the real module by default).
function loadController(name, { Controller = class {}, recovery = loadRecovery() } = {}) {
  const source = read(name)
    .replace('import { Controller } from "@hotwired/stimulus"', "")
    .replace(/import \{ ([^}]+) \} from "chats\/recovery"/, "const { $1 } = recovery")
    .replace("export default class extends Controller", "return class extends Controller")
  return new Function("Controller", "recovery", source)(Controller, recovery)
}

module.exports = { loadRecovery, loadController }
