import { Controller } from "@hotwired/stimulus"

// chats--debounced-submit: submit a GET filter form shortly after typing.
//
// Keep the form outside the Turbo Frame it targets so focus stays in the
// search field while the results frame refreshes.
export default class extends Controller {
  static values = {
    delay: { type: Number, default: 250 }
  }

  connect() {
    this.timeout = null
  }

  disconnect() {
    this.clear()
  }

  queue(event) {
    if (event?.isComposing) return

    this.clear()
    this.timeout = window.setTimeout(() => {
      this.submit()
    }, this.delayValue)
  }

  submit() {
    this.clear()
    this.element.requestSubmit()
  }

  clear() {
    if (!this.timeout) return

    window.clearTimeout(this.timeout)
    this.timeout = null
  }
}
