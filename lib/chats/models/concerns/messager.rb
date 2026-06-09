# frozen_string_literal: true

module Chats
  # Included by `acts_as_messager`. Gives any model an inbox and the two
  # verbs that make the whole gem read like plain English:
  #
  #   alice.chat_with(bob)                       # find-or-create the DM
  #   alice.chat_with(bob, about: ride)          # the DM about that ride
  #   alice.chat_with(bob, carol, title: "Trip") # a group
  #
  #   alice.message!(bob, "hola!")               # DM in one line
  #   alice.message!(conversation, "hola!")      # or into a conversation
  #
  #   alice.chats                                # her inbox, newest first
  #   alice.unread_chats_count                   # for the nav badge
  module Messager
    extend ActiveSupport::Concern

    included do
      has_many :chat_participations,
               class_name: "Chats::Participant",
               as: :messager,
               inverse_of: :messager,
               dependent: :destroy

      has_many :chat_conversations,
               through: :chat_participations,
               source: :conversation

      # `dependent: :nullify`: when a messager account is destroyed, their
      # messages stay as context for everyone else (sender shows as a
      # localized "deleted account"), mirroring what every serious messaging
      # product does. The sender-presence validation only runs on create, so
      # orphaned rows remain valid.
      has_many :chat_messages,
               class_name: "Chats::Message",
               as: :sender,
               dependent: :nullify

      Chats.register_messager(self)
    end

    # Find-or-create a conversation with one or more other messagers.
    # One other → the direct thread (per-pair, or per-pair-per-subject when
    # `about:` is given). Several others → a group.
    #
    # Raises Chats::BlockedError / Chats::NotAllowedError — see
    # Conversation.direct_between! / .group!.
    def chat_with(*others, about: nil, title: nil)
      others = others.flatten.compact
      raise ArgumentError, "chat_with requires at least one other messager" if others.empty?

      if others.size == 1
        Chats::Conversation.direct_between!(self, others.first, about: about)
      else
        Chats::Conversation.group!(self, others, title: title, about: about)
      end
    end

    # Send a message — to a messager (resolving/creating the direct thread)
    # or straight into a Chats::Conversation. Returns the Chats::Message.
    #
    #   alice.message!(bob, "are you coming?")
    #   alice.message!(bob, "about the ride", about: ride)
    #   alice.message!(conversation, "hi all!", files: [photo])
    def message!(target, body = nil, about: nil, files: [], reply_to: nil)
      conversation =
        case target
        when Chats::Conversation then target
        else chat_with(target, about: about)
        end

      attributes = { sender: self, body: body, reply_to: reply_to }
      attributes[:files] = files if files.present?
      conversation.messages.create!(**attributes)
    end

    # The inbox: every active conversation, blocked counterparts hidden,
    # newest activity first. A relation — chain `.limit`, `.includes`, etc.
    def chats
      Chats::Conversation.inbox_for(self)
    end

    # Number of conversations with unread messages (the WhatsApp-style nav
    # badge counts conversations, not messages — 47 unread messages in one
    # thread is still "1 thing to deal with").
    def unread_chats_count
      # reorder(nil): the inbox scope orders by a COALESCE expression, which
      # PostgreSQL rejects inside a COUNT(DISTINCT …) aggregate.
      chats.unread_by(self).reorder(nil).distinct.count
    end

    def unread_chats?
      chats.unread_by(self).reorder(nil).exists?
    end

    # This messager's participant row in +conversation+ (nil when not in it).
    def chat_participation_in(conversation)
      conversation.participant_for(self)
    end
  end
end
