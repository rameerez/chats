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
  # activity descending. Grouping happens HERE and nowhere else.
  #
  # == Why `inbox_limit` bounds ROWS, not conversations
  #
  # A stacked counterpart can hold hundreds of threads. Limiting the raw
  # conversation query first would let a busy support desk EVICT everything
  # else from the inbox — 200 desk threads and not one message from a friend.
  # So the two populations are queried separately: ordinary conversations get
  # the limit, stacked ones get their own bounded window, and the limit is
  # applied again to the ROWS that come out. A stack's numbers
  # (`open_count`, `unread_count`) are then GLOBAL, read with two indexed
  # aggregates per stack — never per conversation, and never by loading the
  # stack to count it.
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

    # Conversation | InboxGroup rows, newest activity first, at most
    # `config.inbox_limit` of them.
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

    # Every conversation loaded behind the rows — the flat list, stacked
    # threads included.
    def conversations
      rows
      @conversations
    end

    # { conversation_id => unread message count } — one grouped query for
    # every loaded conversation, which is what the row badges read.
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

    def limit
      Chats.config.inbox_limit
    end

    # Memoized so `config.inbox_scope` is consulted ONCE per inbox for the
    # row query, however many legs it is split into (the stack aggregates
    # apply it separately, to their own relation).
    def base_relation
      @base_relation ||= begin
        relation = Chats::Conversation.inbox_for(viewer)
                                      .includes(:last_message, :subject, participants: :messager)
        Chats.config.inbox_scope.call(relation, viewer) || relation
      end
    end

    # The polymorphic types worth splitting out. Empty when nothing stacks
    # (an ordinary app pays nothing) and when the inbox is already filtered
    # to one counterpart.
    def grouped_types
      @grouped_types ||= filtered? ? [] : Chats.grouped_messager_types
    end

    # Seats held by a stacked messager — never the viewer's own seat, so a
    # stacked messager's OWN inbox stays flat.
    def stacked_seats
      Chats::Participant.select(:conversation_id)
                        .where(messager_type: grouped_types)
                        .where.not(messager_type: viewer.class.polymorphic_name, messager_id: viewer.id)
    end

    def load_conversations
      if filtered?
        @ungrouped = apply_search(filter_to_counterpart(base_relation).limit(limit))
        @stacked = []
      elsif grouped_types.empty?
        @ungrouped = apply_search(base_relation.limit(limit))
        @stacked = []
      else
        stacked = Chats::Conversation.direct.where(id: stacked_seats)
        @ungrouped = apply_search(base_relation.where.not(id: stacked).limit(limit))
        # Ordered by recency and limited like the other leg, which also makes
        # the FIRST conversation of each counterpart that counterpart's
        # freshest — that's the one the stacked row previews.
        @stacked = apply_search(base_relation.direct.where(id: stacked_seats).limit(limit))
      end

      @conversations = @ungrouped + @stacked
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
      load_conversations
      rows = @ungrouped.dup
      stacks = {}

      @stacked.each do |conversation|
        counterpart = stacked_counterpart(conversation)
        # The SQL prefilter matches by polymorphic type; an STI sibling that
        # isn't actually grouped lands here and goes back to being a row.
        next rows << conversation if counterpart.nil?

        (stacks[Chats.messager_key(counterpart)] ||= [counterpart, []]).last << conversation
      end

      rows.concat(stacks.each_value.map { |messager, members| build_group(messager, members) })
      rows.sort_by { |row| -sort_key(row).to_f }.first(limit)
    end

    def build_group(messager, members)
      totals = stack_totals(messager)

      Chats::InboxGroup.new(
        messager: messager,
        conversations: members.sort_by { |conversation| -sort_key(conversation).to_f },
        unread_count: totals[:unread],
        open_count: totals[:open]
      )
    end

    # What a stacked row says about the WHOLE stack, in two indexed
    # aggregates — independent of how deep the stack is, and of how much of
    # it we loaded.
    def stack_totals(messager)
      scope = Chats::Conversation.inbox_for(viewer).reorder(nil).direct.where(
        id: Chats::Participant.select(:conversation_id).where(
          messager_type: messager.class.polymorphic_name, messager_id: messager.id
        )
      )
      scope = Chats.config.inbox_scope.call(scope, viewer) || scope

      {
        open: scope.distinct.count,
        unread: scope.unread_by(viewer).reorder(nil).count("chats_messages.id")
      }
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
    # and message bodies. Each leg is capped (config.inbox_limit), so
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
      return [] if Chats.config.encrypt_messages || conversations.empty?

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
