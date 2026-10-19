// chats/sheet: what every full-screen sheet in the corner shares, the
// dock's (its panel, a window in front) and the tray's (an open item).
//
// A sheet is modal: everything around it is `inert` and the page behind it
// doesn't scroll. Two sheets can overlap for a moment (one opens as the
// other closes, in either order), so the page's inert and its scroll lock
// are HELD BY OWNER: a node stays inert, and the page locked, while anyone
// still holds it, and one sheet closing never releases what another holds.
// A node the host made inert itself is never touched.
//
// Not a controller: outside controllers/ so the eager loader never tries to
// register it (config/importmap.rb).

const held = new Map() // node → the owners holding it inert
const locks = new Set() // the owners holding the page's scroll

// Everything on the page but +element+: the siblings of it and of each of
// its ancestors, up to <body>. A host may render the corner inside a layout
// wrapper, and inerting the wrapper would inert the sheet too.
export function around(element) {
  const nodes = []
  for (let node = element; node?.parentElement && node !== document.body; node = node.parentElement) {
    nodes.push(...Array.from(node.parentElement.children).filter((sibling) => sibling !== node))
  }
  return nodes
}

export function holdInert(owner, nodes) {
  nodes.forEach((node) => {
    let owners = held.get(node)
    if (!owners) {
      if (node.inert) return // the host's own: not ours to hold, nor to release
      owners = new Set()
      held.set(node, owners)
    }
    owners.add(owner)
    node.inert = true
  })
}

export function releaseInert(owner) {
  held.forEach((owners, node) => {
    if (!owners.delete(owner) || owners.size) return
    held.delete(node)
    node.inert = false
  })
}

export function lockScroll(owner, locked) {
  if (locked) {
    locks.add(owner)
  } else {
    locks.delete(owner)
  }
  document.documentElement.classList.toggle("chats-dock-sheet-open", locks.size > 0)
}

// Full-screen means the VISIBLE viewport: with the keyboard up it is
// shorter than 100dvh, and a composer must sit on the keys. Sets the
// variables the sheet's CSS reads on +element+, and says when the keyboard
// is up (on a phone, where +compact+).
export function fitViewport(element, compact) {
  const viewport = window.visualViewport
  if (!viewport) return

  element.style.setProperty("--chats-vvh", `${viewport.height}px`)
  element.style.setProperty("--chats-vv-top", `${viewport.offsetTop}px`)
  element.classList.toggle("chats-dock--keyboard", Boolean(compact) && window.innerHeight - viewport.height > 150)
}
