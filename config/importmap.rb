# frozen_string_literal: true

# Pinned under "controllers/chats/..." ON PURPOSE: the stock Rails Stimulus
# setup (app/javascript/controllers/index.js) runs
# `eagerLoadControllersFrom("controllers", application)`, which scans the
# rendered importmap for ^controllers/.*_controller$ keys and registers each
# one, deriving identifiers from paths — these become "chats--thread",
# "chats--composer", etc. with ZERO host JavaScript changes. (stimulus-rails,
# app/assets/javascripts/stimulus-loading.js, registerControllerFromPath.)
#
# Hosts can override either controller by pinning the same key themselves —
# the engine's importmap is drawn FIRST (unshifted in Chats::Engine), and
# importmap-rails resolves duplicate pins last-wins.
pin "controllers/chats/thread_controller", to: "chats/thread_controller.js"
pin "controllers/chats/composer_controller", to: "chats/composer_controller.js"
pin "controllers/chats/debounced_submit_controller", to: "chats/debounced_submit_controller.js"
pin "controllers/chats/refresh_inbox_controller", to: "chats/refresh_inbox_controller.js"
