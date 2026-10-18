# frozen_string_literal: true

# What `rails new` + `rails turbo:install stimulus:install` give a host: Turbo,
# Stimulus, and the stock eager loader that registers every
# controllers/*_controller pin. The engine's own pins (controllers/chats/*)
# are added by Chats::Engine's importmap initializer — the importmap test
# asserts they land here — and are registered by that same loader, with no
# line of host JavaScript naming them.
pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from File.expand_path("../app/javascript/controllers", __dir__), under: "controllers"
