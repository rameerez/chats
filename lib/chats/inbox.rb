# frozen_string_literal: true

module Chats
  # THE inbox query, in one object: load a viewer's recent conversations,
  # optionally filter them, and fold the ones that belong to a stacked
  # counterpart into Chats::InboxGroup rows.
  #
  #   Chats::Inbox.for(alice)                       # rows, newest activity first
  #   Chats::Inbox.for(alice, query: "madrid")      # the search box
  #   Chats::Inbox.for(alice, with: support_desk)   # one stack's contents
  #   Chats::Inbox.for(alice, limit: 10)            # the messaging dock's recent list
  #
  # Rows are `Chats::Conversation | Chats::InboxGroup`, sorted by last
  # activity descending. Grouping happens HERE and nowhere else, and so does
  # the rule that a conversation nobody has written in is never listed.
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

    attr_reader :viewer, :query, :with, :limit

    class << self
      # The inbox for +viewer+. Returns a Chats::Inbox, which enumerates its
      # rows (`to_a` for a plain Array).
      def for(viewer, query: nil, with: nil, limit: nil)
        new(viewer, query: query, with: with, limit: limit)
      end
    end

    # +limit+ is how many ROWS come back (`config.inbox_limit` by default).
    # A smaller one is a smaller query, not a slice of the big one — except
    # while searching, which still looks through the whole `inbox_limit`
    # window (a match is no less a match for being the eleventh most
    # recent conversation) and then returns at most +limit+ hits.
    def initialize(viewer, query: nil, with: nil, limit: nil)
      @viewer = viewer
      @query = query.to_s.strip.presence
      @with = with
      @limit = Integer(limit || Chats.config.inbox_limit).clamp(1, Chats.config.inbox_limit)
    end

    # Conversation | InboxGroup rows, newest activity first, at most
    # +limit+ of them.
    def rows
      @rows ||= build_rows
    end

    # Yield each row (Enumerable gives `map`, `select`, `find`, … from here).
    def each(&)
      rows.each(&)
    end

    # The rows as a plain Array.
    def to_a
      rows
    end

    # How many rows the inbox has.
    def size
      rows.size
    end

    # Whether the inbox has any rows at all.
    def any?
      rows.any?
    end

    # Whether the inbox has no rows.
    def empty?
      rows.empty?
    end

    # The conversations behind the rows, stacked threads included. Stays an
    # ActiveRecord::Relation (already loaded) in the simple case — no search,
    # nothing stacked — so an inbox ejected under 0.1.x can still chain
    # `.where` or hand it to a paginator. Becomes an Array once rows had to
    # be assembled in Ruby.
    def conversations
      rows
      @flat
    end

    # { conversation_id => unread message count } — one grouped query for
    # every loaded conversation, which is what the row badges read.
    def unread_counts
      @unread_counts ||= Chats::Conversation.unread_counts_for(viewer, conversations)
    end

    # Unread messages in one conversation, from the grouped query above.
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

    # How many conversations each leg of the query loads: the row limit, or
    # the whole inbox window while a search filters it in Ruby.
    def window
      query ? Chats.config.inbox_limit : limit
    end

    # The viewer's own inbox relation (`Messager#chats`: `inbox_for` with
    # `config.inbox_scope` applied, and whatever the host's model adds on
    # top), memoized so it is built ONCE per inbox however many legs the
    # row query is split into (the stack aggregates build their own).
    #
    # Only conversations somebody wrote in (Conversation.with_messages): one
    # that was opened and never used is not listed — not as a row, not in a
    # stack, not in search, not in the `?with=` view. It still OPENS, because
    # authorization reads `viewer.chats`, not this.
    def base_relation
      @base_relation ||= listed(viewer.chats).includes(:last_message, :subject, participants: :messager)
    end

    # What a list may show of +relation+. The one place the rule lives, so
    # the rows and the stack totals can never disagree about it.
    def listed(relation)
      relation.with_messages
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
        @ungrouped_relation = filter_to_counterpart(base_relation).limit(window)
        @stacked = []
      elsif grouped_types.empty?
        @ungrouped_relation = base_relation.limit(window)
        @stacked = []
      else
        stacked = Chats::Conversation.direct.where(id: stacked_seats)
        @ungrouped_relation = base_relation.where.not(id: stacked).limit(window)
        recent = base_relation.direct.where(id: stacked_seats).except(:includes).select(:id).limit(window)
        # Preserve the recent search window, plus the freshest conversation
        # of each counterpart. A busy stack cannot consume another stack's
        # row; at most twice the row limit is materialized.
        candidates = base_relation.where(id: limited_ids(recent))
                                  .or(base_relation.where(id: limited_ids(stack_representatives)))
        @stacked = apply_search(candidates)
      end

      @ungrouped = apply_search(@ungrouped_relation)
      # The relation itself when nothing had to be assembled in Ruby (it is
      # loaded, so iterating it costs nothing extra); the flat Array otherwise.
      @flat = @stacked.empty? && query.nil? ? @ungrouped_relation : @ungrouped + @stacked
    end

    # MySQL rejects LIMIT directly in an IN subquery. A derived table keeps
    # the bounded selection in SQL and works on all three supported adapters.
    def limited_ids(relation)
      Chats::Conversation.from(relation, :limited_conversations).select(:id)
    end

    # ROW_NUMBER works on every supported adapter (PostgreSQL, SQLite and
    # MySQL 8). Ranking in SQL avoids loading an entire busy desk's history.
    def stack_representatives
      activity = "COALESCE(chats_conversations.last_message_at, chats_conversations.created_at)"
      ranking = "ROW_NUMBER() OVER (PARTITION BY stack_seats.messager_type, stack_seats.messager_id " \
                "ORDER BY #{activity} DESC, chats_conversations.id DESC) AS stack_rank"
      ranked = base_relation.direct.except(:includes, :order)
                            .joins("INNER JOIN chats_participants stack_seats " \
                                   "ON stack_seats.conversation_id = chats_conversations.id")
                            .where(stack_seats: { messager_type: grouped_types })
                            .where.not(stack_seats: { messager_type: viewer.class.polymorphic_name,
                                                      messager_id: viewer.id })
                            .select("chats_conversations.id, #{activity} AS activity_at", ranking)
      Chats::Conversation.from(ranked, :ranked_stacks).where("stack_rank = 1")
                         .order(Arel.sql("activity_at DESC, id DESC")).limit(window).select(:id)
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
      sort_rows(rows).first(limit)
    end

    # Newest activity first, exactly like the SQL the relation would have
    # used (COALESCE(last_message_at, created_at) DESC), at full timestamp
    # precision — `to_r`, not `to_f`, because two messages a microsecond
    # apart must not collapse into a tie. Ties break on id, so the order is
    # total and a row never shuffles between renders.
    def sort_rows(rows)
      rows.sort do |a, b|
        by_activity = sort_key(b).to_r <=> sort_key(a).to_r
        by_activity.zero? ? compare_ids(b, a) : by_activity
      end
    end

    def build_group(messager, members)
      totals = stack_totals(messager)

      Chats::InboxGroup.new(
        messager: messager,
        conversations: sort_rows(members),
        unread_count: totals[:unread],
        open_count: totals[:open]
      )
    end

    # What a stacked row says about the WHOLE stack, in two indexed
    # aggregates — independent of how deep the stack is, and of how much of
    # it we loaded.
    def stack_totals(messager)
      scope = listed(viewer.chats).reorder(nil).direct.where(
        id: Chats::Participant.select(:conversation_id).where(
          messager_type: messager.class.polymorphic_name, messager_id: messager.id
        )
      )

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
      row.last_message_at || (row.respond_to?(:created_at) ? row.created_at : nil) || Chats::Conversation::EPOCH
    end

    # The total-order tiebreak: a conversation's own id, a stack's freshest
    # conversation's id. Works for bigint and uuid keys alike, and never
    # raises on a pair it can't compare — it just calls them equal.
    def compare_ids(a, b)
      left = tiebreak(a)
      right = tiebreak(b)
      return 0 if left.nil? || right.nil? || left.class != right.class

      left <=> right
    end

    def tiebreak(row)
      row.is_a?(Chats::InboxGroup) ? row.conversation&.id : row.id
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
