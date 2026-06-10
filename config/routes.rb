# frozen_string_literal: true

Chats::Engine.routes.draw do
  # `path: ""` keeps URLs short under the host's mount point: with
  # `mount Chats::Engine => "/messages"` the inbox is /messages, a thread is
  # /messages/:id, sending is POST /messages/:conversation_id/messages.
  resources :conversations, path: "", only: %i[index show create] do
    member do
      post :read    # advance the viewer's read horizon (mark as read)
      post :typing  # ephemeral "X is typing…" ping (see Chats::Broadcasts.typing)
      post :leave   # leave a group (direct threads can't be left — block instead)
      post :mute
      post :unmute
      get :refresh  # stale-thread catch-up after sleep/disconnect (?since=ms)
    end

    resources :messages, only: %i[show create update destroy] do
      # Tap-to-toggle, so `create` both adds and removes (see Reaction.toggle!).
      resources :reactions, only: :create
    end
  end

  root to: "conversations#index"
end
