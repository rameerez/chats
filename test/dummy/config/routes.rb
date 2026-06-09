# frozen_string_literal: true

Rails.application.routes.draw do
  # Mount the engine the way a real host does: at a host-chosen path. We
  # deliberately mount at "/messages" (the README's suggested mount point)
  # to prove the gem hardcodes no prefix — the inbox lives at /messages, a
  # thread at /messages/:id, and the host gets the `chats.` URL-helper proxy
  # the integration tests rely on.
  mount Chats::Engine => "/messages"

  # Test-only session endpoint so integration tests can act as a user
  # without dragging a real auth framework into the dummy.
  post "/test_login", to: "sessions#create", as: :test_login

  root to: "sessions#home"
end
