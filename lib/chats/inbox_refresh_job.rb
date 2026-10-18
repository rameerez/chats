# frozen_string_literal: true

module Chats
  # One messager's inbox refresh (Chats::Broadcasts.refresh_inbox_of): at
  # most one queued per messager, standing for every write that commits
  # before it starts. A messager deleted before it ran has no inbox.
  class InboxRefreshJob < ActiveJob::Base
    discard_on ActiveJob::DeserializationError

    def perform(messager)
      Chats::Broadcasts.refresh_inbox_now(messager)
    end
  end
end
