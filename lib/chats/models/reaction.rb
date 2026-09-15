# frozen_string_literal: true

module Chats
  # An emoji reaction on a message. One row per (message, reactor, emoji) —
  # the unique index makes `toggle!` race-safe. Reactors are polymorphic like
  # every actor in this gem.
  class Reaction < ApplicationRecord
    self.table_name = "chats_reactions"

    # Reactions are short by nature; 16 chars comfortably fits any emoji
    # grapheme cluster (ZWJ sequences like 👨‍👩‍👧‍👦 are up to ~11 chars) while
    # making "smuggle a paragraph into a reaction" impossible.
    EMOJI_MAX_LENGTH = 16

    belongs_to :message, class_name: "Chats::Message", inverse_of: :reactions
    belongs_to :reactor, polymorphic: true

    validates :emoji, presence: true, length: { maximum: EMOJI_MAX_LENGTH }
    validates :emoji, uniqueness: { scope: %i[message_id reactor_type reactor_id] }
    validate :reactions_must_be_enabled, on: :create
    validate :reactor_must_be_participant, on: :create

    # ONE after_commit with on: — NOT separate after_create_commit +
    # after_destroy_commit macros: registering the SAME method name through
    # two *_commit macros silently keeps only the last registration (each
    # macro defines an after_commit filter keyed by method name). Documented
    # Rails behavior: https://guides.rubyonrails.org/active_record_callbacks.html#using-both-after-create-commit-and-after-update-commit
    after_commit :broadcast_change, on: %i[create destroy]

    # Add the reaction if absent, remove it if present (the universal
    # tap-to-toggle semantic). Returns the created reaction, or false when
    # toggled off. Race-safe: a concurrent double-tap resolves through the
    # unique index instead of raising.
    def self.toggle!(message:, reactor:, emoji:)
      # Reacting is a write to the conversation, so a locked one refuses it —
      # in BOTH directions: you can't add a reaction to a closed thread, and
      # you can't take one back either. Same rule as editing and deleting.
      message&.conversation&.refuse_writes_when_locked!

      existing = find_by(message: message, reactor: reactor, emoji: emoji)
      if existing
        existing.destroy!
        false
      else
        create!(message: message, reactor: reactor, emoji: emoji)
      end
    rescue ActiveRecord::RecordNotUnique
      # Lost the race with an identical create — treat as toggle-off.
      find_by(message: message, reactor: reactor, emoji: emoji)&.destroy!
      false
    end

    # Grouped summary for rendering: [["👍", 3], ["🚗", 1]] — stable order so
    # bubbles don't shuffle when counts change.
    def self.summary_for(message)
      where(message: message).group(:emoji).count.sort_by { |emoji, _count| emoji }
    end

    private

    def reactions_must_be_enabled
      errors.add(:base, :reactions_disabled) unless Chats.config.reactions
    end

    def reactor_must_be_participant
      return if message.nil? || reactor.nil?

      errors.add(:reactor, :not_a_participant) unless message.conversation.participant?(reactor)
    end

    def broadcast_change
      Chats::Broadcasts.message_updated(message) unless message.destroyed?
    end
  end
end
