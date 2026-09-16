# frozen_string_literal: true

module Chats
  # Base class for every error this gem raises, so hosts can
  # `rescue Chats::Error` to catch anything chats-specific.
  class Error < StandardError; end

  # Raised by `Chats.configure` / setters when the configuration is invalid
  # (unknown filter mode, blank class name, non-callable hook, …).
  class ConfigurationError < Error; end

  # Raised when trying to open a conversation with (or send a message to)
  # someone the sender is blocked with — in either direction. Controllers
  # translate this into a friendly flash; model-level callers get the raise.
  class BlockedError < Error; end

  # Raised when the host `can_message` policy (or a feature flag like
  # `config.groups = false`) forbids the attempted action.
  class NotAllowedError < Error; end

  # Raised when a conversation's SUBJECT has locked it (see
  # Chats::ChatSubject#chat_locked?) and something tries to write to it
  # anyway — send, edit, delete, react. A subclass of NotAllowedError on
  # purpose: a host that already rescues NotAllowedError keeps working, and
  # one that wants to show the lock notice specifically can rescue this.
  # System messages are never refused: the app must always be able to say
  # "this was closed" in the thread it just closed.
  class LockedError < NotAllowedError
    attr_reader :conversation

    def initialize(message = nil, conversation: nil)
      @conversation = conversation
      super(message || conversation&.locked_notice || "this conversation is closed")
    end
  end
end
