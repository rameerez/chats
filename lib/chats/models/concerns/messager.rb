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
  #   alice.message!(bob, "Let's play!",         # with a button under it
  #                  action: { label: "Join my room", url: "/play/abcd" })
  #
  #   alice.chats                                # her inbox, newest first
  #   alice.unread_chats_count                   # for the nav badge
  module Messager
    extend ActiveSupport::Concern

    # What `acts_as_messager` declares about a messager class. The defaults
    # are exactly 0.1.x behaviour, so a bare `acts_as_messager` is unchanged.
    DEFAULT_CHAT_OPTIONS = {
      notifications: true,
      blockable: true,
      inbox: :default,
      group_path: nil,
      verified: false
    }.freeze

    INBOX_MODES = %i[default grouped].freeze

    # Validate + freeze the macro's options, failing at BOOT with a plain
    # English message rather than at 3am with a NoMethodError.
    def self.normalize_options(notifications:, blockable:, inbox:, group_path:, verified: false)
      inbox = inbox.to_sym
      unless INBOX_MODES.include?(inbox)
        raise Chats::ConfigurationError,
              "acts_as_messager inbox: must be one of #{INBOX_MODES.inspect}, got #{inbox.inspect}"
      end

      if group_path && !group_path.respond_to?(:call)
        raise Chats::ConfigurationError,
              "acts_as_messager group_path: must respond to #call (a proc/lambda), got #{group_path.inspect}"
      end

      # Deliberately STRICTER than its boolean neighbours, which coerce with
      # `!!`. "Official account" is a trust claim shown to everyone who talks
      # to this messager, so `verified: "false"` (an ENV var, a YAML
      # round-trip) has to fail at boot rather than quietly verify it.
      unless [true, false].include?(verified)
        raise Chats::ConfigurationError,
              "acts_as_messager verified: must be true or false, got #{verified.inspect}"
      end

      {
        notifications: !!notifications,
        blockable: !!blockable,
        inbox: inbox,
        group_path: group_path,
        verified: verified
      }.freeze
    end

    class_methods do
      # True unless declared with `acts_as_messager notifications: false`.
      def chat_notifications?
        chat_options[:notifications]
      end

      # True unless declared with `acts_as_messager blockable: false`.
      def chat_blockable?
        chat_options[:blockable]
      end

      # :default | :grouped (see Chats::Inbox).
      def chat_inbox_mode
        chat_options[:inbox]
      end

      # Whether every direct conversation with this messager folds into ONE
      # inbox row (see Chats::InboxGroup).
      def chat_grouped_inbox?
        chat_inbox_mode == :grouped
      end

      # The `group_path:` callable, or nil (then the stacked row links to the
      # filtered inbox).
      def chat_group_path
        chat_options[:group_path]
      end

      # True when declared with `acts_as_messager verified: true` — an
      # OFFICIAL account (a support desk, an organization, a brand). The
      # bundled views badge its name wherever they show it.
      def chat_verified?
        chat_options[:verified]
      end
    end

    included do
      # Declared by `acts_as_messager`; a plain `include Chats::Messager`
      # gets the defaults. class_attribute so STI subclasses inherit it.
      class_attribute :chat_options,
                      instance_accessor: false,
                      default: Chats::Messager::DEFAULT_CHAT_OPTIONS

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
    #
    # `author:` is the human (or bot) writing on the SENDER's behalf — an
    # agent answering from a support desk seat. It signs the bubble; the
    # sender stays the conversation identity. See Chats::Message#signed?.
    #
    #   desk.message!(alice, "On it!", author: lucia)
    #
    # `action:` is the one featured button under the words — a label and a
    # url (see Chats::Action). It rides on a message the body rules already
    # accept; an action alone is not a message.
    #
    #   alice.message!(bob, "Let's play!", action: { label: "Join my room", url: room_path(room) })
    def message!(target, body = nil, about: nil, files: [], reply_to: nil, author: nil, action: nil)
      conversation =
        case target
        when Chats::Conversation then target
        else chat_with(target, about: about)
        end

      attributes = { sender: self, body: body, reply_to: reply_to, author: author, action: action }
      attributes[:files] = files if files.present?
      conversation.messages.create!(**attributes)
    end

    # The inbox: every active conversation, blocked counterparts hidden,
    # `config.inbox_scope` applied, newest activity first. A relation —
    # chain `.limit`, `.includes`, etc.
    #
    # THE one definition of "what is in this messager's inbox": the inbox
    # screen, the unread count, the live badge and a host's own queries all
    # read it, so a conversation the scope hides is hidden everywhere. Until
    # 0.4.1 the badge counted through the raw `inbox_for` relation and could
    # light up for a conversation the inbox would never show.
    #
    # It is also the AUTHORIZATION relation (every engine lookup is
    # `viewer.chats.find(id)`), which is why it includes conversations
    # nobody has written in yet: the thread you just opened must open. The
    # lists narrow it with `Chats::Conversation.with_messages` (see
    # Chats::Inbox); `chats.with_messages` is what your own lists want too.
    def chats
      relation = Chats::Conversation.inbox_for(self)
      Chats.config.inbox_scope.call(relation, self) || relation
    end

    # Number of conversations with unread messages (the WhatsApp-style nav
    # badge counts conversations, not messages — 47 unread messages in one
    # thread is still "1 thing to deal with").
    def unread_chats_count
      # No `with_messages` needed to agree with the inbox: `unread_by` joins
      # the messages, so a conversation nobody has written in can never be
      # counted. reorder(nil): the inbox scope orders by a COALESCE
      # expression, which PostgreSQL rejects inside a COUNT(DISTINCT …).
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
