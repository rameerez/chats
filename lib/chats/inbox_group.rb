# frozen_string_literal: true

module Chats
  # A stack of direct conversations that share one counterpart, shown as a
  # SINGLE inbox row. Built by Chats::Inbox for messagers declared with
  # `acts_as_messager inbox: :grouped` — a support desk, a marketplace
  # storefront, any seat a person ends up with many separate threads with.
  #
  # It quacks like the parts of Chats::Conversation the inbox row needs
  # (+last_message+, +last_message_at+, +unread_count+) so the two row
  # partials stay symmetrical.
  class InboxGroup
    attr_reader :messager, :conversations, :unread_count

    def initialize(messager:, conversations:, unread_count: 0)
      @messager = messager
      @conversations = conversations
      @unread_count = unread_count
    end

    # How many conversations are stacked here (within the inbox window —
    # see Chats.config.inbox_limit).
    def open_count
      conversations.size
    end

    # A stack of one is really just a conversation: the row links straight to
    # it, and the thread carries a "see all" link back to the stack.
    def single?
      open_count == 1
    end

    def conversation
      conversations.first
    end

    def last_message
      conversation&.last_message
    end

    # The sort key the inbox orders rows by: the freshest activity in the
    # stack (mirrors Conversation.recent_first's COALESCE).
    def last_message_at
      conversations.filter_map { |c| c.last_message_at || c.created_at }.max
    end

    def unread?
      unread_count.positive?
    end

    def title_for(_viewer)
      Chats.display_name_for(messager)
    end

    # Stable DOM id for the row (no AR record to derive one from).
    def dom_id
      "chats_inbox_group_#{messager.class.polymorphic_name.underscore.tr("/", "_")}_#{messager.id}"
    end

    # The signed, purpose-scoped GlobalID that filters the inbox to this
    # stack (`GET /conversations?with=…`).
    def with_sgid
      Chats.inbox_with_sgid(messager)
    end
  end
end
