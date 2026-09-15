# frozen_string_literal: true

module Chats
  # THE inbox query, in one object: load a viewer's recent conversations,
  # optionally filter them, and fold the ones that belong to a stacked
  # counterpart into Chats::InboxGroup rows.
  #
  #   Chats::Inbox.for(alice)                       # rows, newest activity first
  #   Chats::Inbox.for(alice, query: "madrid")      # the search box
  #   Chats::Inbox.for(alice, with: support_desk)   # one stack's contents
  #
  # Rows are `Chats::Conversation | Chats::InboxGroup`, sorted by last
  # activity descending. Grouping happens HERE and nowhere else, so
  # pagination stays honest: stacks are folded out of the already-limited
  # relation (`config.inbox_limit`) plus ONE grouped unread-count query — we
  # never load a messager's whole history to count it.
  class Inbox
    include Enumerable

    attr_reader :viewer, :query, :with

    class << self
      # The inbox for +viewer+. Returns a Chats::Inbox, which enumerates its
      # rows (`to_a` for a plain Array).
      def for(viewer, query: nil, with: nil)
        new(viewer, query: query, with: with)
      end
    end

    def initialize(viewer, query: nil, with: nil)
      @viewer = viewer
      @query = query.to_s.strip.presence
      @with = with
    end

    # Conversation | InboxGroup rows, newest activity first.
    def rows
      @rows ||= build_rows
    end

    def each(&)
      rows.each(&)
    end

    # Array-ish so views and hosts can treat the inbox as the list it is.
    def to_a
      rows
    end
    alias to_ary to_a

    def size
      rows.size
    end

    def any?
      rows.any?
    end

    def empty?
      rows.empty?
    end

    # The conversations behind the rows (already limited, filtered, loaded).
    def conversations
      @conversations ||= load_conversations
    end

    # { conversation_id => unread message count } — the ONE grouped
    # follow-up query the row badges (and the stack aggregates) read.
    def unread_counts
      @unread_counts ||= Chats::Conversation.unread_counts_for(viewer, conversations)
    end

    def unread_count_for(conversation)
      unread_counts.fetch(conversation.id, 0)
    end

    # The stack-aware badge number: how many inbox ROWS carry unread content
    # (a stack of five unread threads is still one thing to deal with).
    # `Messager#unread_chats_count` is the unstacked count and is unchanged.
    def unread_count
      rows.count do |row|
        row.is_a?(Chats::InboxGroup) ? row.unread? : unread_count_for(row).positive?
      end
    end

    # True when scoped to one counterpart (`?with=`): a stack's contents,
    # which are listed individually rather than re-stacked.
    def filtered?
      with.present?
    end

    private

    def load_conversations
      relation = Chats::Conversation.inbox_for(viewer)
                                    .includes(:last_message, :subject, participants: :messager)
      relation = Chats.config.inbox_scope.call(relation, viewer) || relation
      relation = filter_to_counterpart(relation) if filtered?

      apply_search(relation.limit(Chats.config.inbox_limit))
    end

    # Only the direct threads shared with one counterpart. Direct only, by
    # design: a group that happens to include the desk is not part of the
    # desk's stack.
    def filter_to_counterpart(relation)
      seats = Chats::Participant.select(:conversation_id).where(
        messager_type: with.class.polymorphic_name, messager_id: with.id
      )
      relation.direct.where(id: seats)
    end

    def build_rows
      grouped = Hash.new { |hash, key| hash[key] = [] }
      rows = []

      conversations.each do |conversation|
        counterpart = filtered? ? nil : stacked_counterpart(conversation)

        if counterpart
          grouped[Chats.messager_key(counterpart)] << [counterpart, conversation]
        else
          rows << conversation
        end
      end

      rows.concat(grouped.each_value.map { |pairs| build_group(pairs) })
      rows.sort_by { |row| -sort_key(row).to_f }
    end

    def build_group(pairs)
      members = pairs.map(&:last)

      Chats::InboxGroup.new(
        messager: pairs.first.first,
        conversations: members.sort_by { |c| -sort_key(c).to_f },
        unread_count: members.sum { |c| unread_count_for(c) }
      )
    end

    # The other party of a DIRECT conversation, when their class asked to be
    # stacked (`acts_as_messager inbox: :grouped`). Read from the preloaded
    # participants — no extra query per row.
    def stacked_counterpart(conversation)
      return nil unless conversation.direct?

      other = conversation.participants.find do |participant|
        participant.messager.present? && participant.messager != viewer
      end&.messager

      other if Chats.grouped_inbox?(other)
    end

    def sort_key(row)
      row.last_message_at || (row.respond_to?(:created_at) ? row.created_at : nil)
    end

    # Partial, case-insensitive matching across the inbox metadata users can
    # actually see: participant names, conversation titles, subject labels,
    # and message bodies. The inbox is capped (config.inbox_limit), so
    # metadata is filtered portably in Ruby from the already-preloaded
    # objects while the potentially larger message-body set stays in SQL. No
    # PostgreSQL-only full-text dependency is needed at this scale.
    def apply_search(relation)
      return relation.to_a unless Chats.config.search && query

      loaded = relation.to_a
      normalized_query = query.downcase
      message_match_ids = conversations_matching_body(loaded)

      loaded.select do |conversation|
        message_match_ids.include?(conversation.id) ||
          searchable_metadata(conversation).downcase.include?(normalized_query)
      end
    end

    def conversations_matching_body(conversations)
      return [] if Chats.config.encrypt_messages

      pattern = "%#{Chats::Conversation.sanitize_sql_like(query.downcase)}%"
      Chats::Message.where(conversation_id: conversations.map(&:id), deleted_at: nil)
                    .where("LOWER(chats_messages.body) LIKE ?", pattern)
                    .distinct
                    .pluck(:conversation_id)
    end

    def searchable_metadata(conversation)
      participant_names = conversation.participants.filter_map do |participant|
        Chats.display_name_for(participant.messager) if participant.active?
      end

      [conversation.title, conversation.subject_label, *participant_names].compact.join(" ")
    end
  end
end
