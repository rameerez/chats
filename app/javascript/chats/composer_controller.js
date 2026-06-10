import { Controller } from "@hotwired/stimulus"

// chats--composer: the message box.
//
//   * autosize            grow the textarea with content (capped)
//   * Enter-to-send       desktop only ("pointer: fine") — on touch keyboards
//                         Enter means newline, like every messaging app;
//                         Shift+Enter always inserts a newline; IME
//                         composition (event.isComposing) never sends
//   * typing pings        throttled POST (~1 per 2.5s while typing) that the
//                         server fans out as the chats_typing stream action;
//                         disabled when the server didn't render a typing URL
//   * attachment previews picking files renders a thumbnail strip above the
//                         input (with per-file remove), so "what am I about
//                         to send?" is always visible — a bare counter badge
//                         next to the clip is not an answer
//   * reset-on-success    listens for turbo:submit-end (wired via data-action
//                         on the form) and clears/refocuses only on success —
//                         a 422 keeps the draft intact
export default class extends Controller {
  static targets = ["input", "files", "fileCount", "previews"]
  static values = { typingUrl: String }

  connect() {
    this.lastTypedAt = 0
    this.objectUrls = []
    this.autosize()
  }

  disconnect() {
    this.revokeObjectUrls()
  }

  typed() {
    this.autosize()
    this.pingTyping()
  }

  enterSend(event) {
    if (event.shiftKey || event.isComposing) return
    if (!window.matchMedia("(pointer: fine)").matches) return

    event.preventDefault()
    if (this.empty()) return
    this.element.requestSubmit()
  }

  submitted(event) {
    if (!event.detail.success) return

    this.element.reset()
    this.clearPreviews()
    this.autosize()
    if (this.hasInputTarget) this.inputTarget.focus()
  }

  filesChanged() {
    this.renderPreviews()
  }

  // Drop ONE file from the selection. `<input type="file">.files` is a
  // read-only FileList — the only sanctioned way to edit a selection is to
  // rebuild it through a DataTransfer and assign `input.files` wholesale:
  // https://developer.mozilla.org/docs/Web/API/DataTransfer/items
  removeAttachment(event) {
    event.preventDefault()
    if (!this.hasFilesTarget) return

    const index = Number(event.currentTarget.dataset.index)
    const transfer = new DataTransfer()
    Array.from(this.filesTarget.files).forEach((file, i) => {
      if (i !== index) transfer.items.add(file)
    })
    this.filesTarget.files = transfer.files
    this.renderPreviews()
  }

  // --- Internals ---------------------------------------------------------------

  renderPreviews() {
    const files = this.hasFilesTarget ? Array.from(this.filesTarget.files) : []

    // Legacy count chip — kept for ejected views that still render it; the
    // previews strip is the real affordance.
    if (this.hasFileCountTarget) {
      this.fileCountTarget.textContent = files.length > 0 ? String(files.length) : ""
      this.fileCountTarget.hidden = files.length === 0
    }

    if (!this.hasPreviewsTarget) return

    this.revokeObjectUrls()
    this.previewsTarget.innerHTML = ""
    this.previewsTarget.hidden = files.length === 0

    files.forEach((file, index) => {
      this.previewsTarget.appendChild(this.previewTile(file, index))
    })
  }

  previewTile(file, index) {
    const tile = document.createElement("div")
    tile.className = "chats-composer__preview"

    if (file.type.startsWith("image/")) {
      // Object URLs render the local file without uploading anything yet.
      // They hold memory until revoked, so we track and revoke on re-render:
      // https://developer.mozilla.org/docs/Web/API/URL/createObjectURL_static
      const url = URL.createObjectURL(file)
      this.objectUrls.push(url)
      const img = document.createElement("img")
      img.src = url
      img.alt = file.name
      img.className = "chats-composer__preview-image"
      tile.appendChild(img)
    } else {
      const name = document.createElement("span")
      name.textContent = file.name
      name.className = "chats-composer__preview-name"
      tile.appendChild(name)
    }

    const remove = document.createElement("button")
    remove.type = "button"
    remove.className = "chats-composer__preview-remove"
    remove.setAttribute("aria-label", `✕ ${file.name}`)
    remove.textContent = "✕"
    remove.dataset.index = String(index)
    remove.dataset.action = "chats--composer#removeAttachment"
    tile.appendChild(remove)

    return tile
  }

  clearPreviews() {
    this.revokeObjectUrls()
    if (this.hasPreviewsTarget) {
      this.previewsTarget.innerHTML = ""
      this.previewsTarget.hidden = true
    }
    if (this.hasFileCountTarget) this.fileCountTarget.hidden = true
  }

  revokeObjectUrls() {
    this.objectUrls.forEach((url) => URL.revokeObjectURL(url))
    this.objectUrls = []
  }

  autosize() {
    if (!this.hasInputTarget) return
    const input = this.inputTarget
    input.style.height = "auto"
    input.style.height = `${Math.min(input.scrollHeight, 160)}px`
  }

  pingTyping() {
    if (!this.typingUrlValue || this.empty()) return

    const now = Date.now()
    if (now - this.lastTypedAt < 2500) return
    this.lastTypedAt = now

    fetch(this.typingUrlValue, {
      method: "POST",
      headers: { "X-CSRF-Token": csrfToken(), Accept: "application/json" }
    }).catch(() => {})
  }

  empty() {
    const hasText = this.hasInputTarget && this.inputTarget.value.trim().length > 0
    const hasFiles = this.hasFilesTarget && this.filesTarget.files.length > 0
    return !hasText && !hasFiles
  }
}

function csrfToken() {
  return document.querySelector('meta[name="csrf-token"]')?.content || ""
}
