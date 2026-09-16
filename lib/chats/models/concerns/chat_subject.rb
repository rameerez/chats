# frozen_string_literal: true

module Chats
  # Included by `acts_as_chat_subject`. Lets conversations be *about* a host
  # record — `user.chat_with(driver, about: ride)` — which both threads the
  # right people into the right context and shows up as a context line in
  # the inbox/thread UI.
  #
  # Override +chat_subject_label+ to control that context line:
  #
  #   class Ride::Listing < ApplicationRecord
  #     acts_as_chat_subject
  #     def chat_subject_label = "#{origin_locality} → #{destination_locality}"
  #   end
  module ChatSubject
    extend ActiveSupport::Concern

    included do
      # `nullify`, not `destroy`: deleting the subject (a ride, an order)
      # must never delete people's conversation history — the thread just
      # loses its context line.
      has_many :chat_conversations,
               class_name: "Chats::Conversation",
               as: :subject,
               dependent: :nullify

      Chats.register_chat_subject(self)
    end

    # Short human label shown as the conversation's context line.
    def chat_subject_label
      "#{self.class.model_name.human} #{id}"
    end

    # Whether conversations ABOUT this record still accept messages. The
    # subject already owns the conversation's meaning, so it owns its
    # openness too — a closed ticket, a delivered order, an archived listing:
    #
    #   class Ticket < ApplicationRecord
    #     acts_as_chat_subject
    #     def chat_locked?       = closed?
    #     def chat_locked_notice = "This ticket is closed. Reply to reopen it."
    #   end
    #
    # System messages are exempt (the host can always post "Ticket closed"),
    # and locking is a WRITE rule only: the thread stays readable. See
    # Chats::Conversation#locked?.
    def chat_locked?
      false
    end

    # The sentence shown where the composer would be. Nil falls back to the
    # gem's localized "This conversation is closed."
    def chat_locked_notice
      nil
    end
  end
end
