# frozen_string_literal: true

require "test_helper"

module Chats
  # Chats::Inbox — the one place conversations get limited, scoped, searched
  # and STACKED, so pagination and counts stay honest.
  class InboxTest < ActiveSupport::TestCase
    setup do
      @alice = create_user(name: "Alice")
      @bob = create_user(name: "Bob")
      @carol = create_user(name: "Carol")
      @desk = create_desk(name: "Support")
    end

    # --- plain rows -----------------------------------------------------------

    test "an ordinary inbox is still a flat list, newest activity first" do
      older = @alice.chat_with(@bob)
      @bob.message!(older, "first")
      newer = @alice.chat_with(@carol)
      @carol.message!(newer, "later")

      assert_equal [newer, older], Chats::Inbox.for(@alice).rows
    end

    test "an empty inbox is empty, not nil" do
      inbox = Chats::Inbox.for(@alice)

      assert_empty inbox
      assert_equal [], inbox.to_a
      assert_equal 0, inbox.unread_count
    end

    # --- a conversation with no messages is never listed ----------------------

    test "an opened but unused conversation is not a row" do
      @alice.chat_with(@bob) # the Message button, and then nothing
      used = chatting(@carol)

      assert_equal [used], Chats::Inbox.for(@alice).rows
      assert_equal [used], Chats::Inbox.for(@alice).conversations.to_a
    end

    test "it is listed the moment somebody writes, from either seat" do
      empty = @alice.chat_with(@bob)
      assert_empty Chats::Inbox.for(@alice).rows
      assert_empty Chats::Inbox.for(@bob).rows

      @bob.message!(empty, "hola")

      assert_equal [empty], Chats::Inbox.for(@alice).rows
      assert_equal [empty], Chats::Inbox.for(@bob).rows
    end

    test "a message is a message: a system note alone lists the conversation" do
      ride = @alice.chat_with(@bob, about: create_listing(title: "Ride"))
      ride.post_system_message!("Your ride was cancelled")

      assert_equal [ride], Chats::Inbox.for(@alice).rows, "with_messages is any message, not a person writing"
      assert_includes Chats::Conversation.with_messages, ride
    end

    test "it still OPENS: the authorization relation keeps it" do
      empty = @alice.chat_with(@bob)

      assert_equal empty, @alice.chats.find(empty.id), "the thread you just opened must open"
      assert_not_includes @alice.chats.with_messages, empty
    end

    test "an empty conversation never joins a stack, nor its totals" do
      2.times { |index| @alice.chat_with(@desk, about: create_listing(title: "Empty #{index}")) }
      written = @alice.chat_with(@desk, about: create_listing(title: "Written"))
      @desk.message!(written, "ticket")

      group = Chats::Inbox.for(@alice).rows.sole

      assert_instance_of Chats::InboxGroup, group
      assert_equal 1, group.open_count, "the stack counts only what it lists"
      assert group.single?, "so a stack of one written thread links straight to it"
      assert_equal [written], group.conversations
      assert_equal 1, group.unread_count
    end

    test "a stack made only of empty conversations is no row at all" do
      2.times { |index| @alice.chat_with(@desk, about: create_listing(title: "Empty #{index}")) }

      assert_empty Chats::Inbox.for(@alice).rows
    end

    test "the ?with= view lists only the written threads of the stack" do
      @alice.chat_with(@desk, about: create_listing(title: "Empty"))
      written = chatting(@desk, about: create_listing(title: "Written"))

      assert_equal [written], Chats::Inbox.for(@alice, with: @desk).rows
    end

    test "search never finds an empty conversation, even by its metadata" do
      @alice.chat_with(@bob, about: create_listing(title: "Madrid → Barcelona"))
      written = chatting(@carol, about: create_listing(title: "Madrid → Sevilla"))

      assert_equal [written], Chats::Inbox.for(@alice, query: "madrid").rows
      assert_empty Chats::Inbox.for(@alice, query: "bob").rows, "nor by the counterpart's name"
    end

    test "the unread numbers agree with the rows" do
      @alice.chat_with(@bob)
      dm = @alice.chat_with(@carol)
      @carol.message!(dm, "unread")

      inbox = Chats::Inbox.for(@alice)

      assert_equal 1, inbox.unread_count
      assert_equal 1, @alice.unread_chats_count, "an empty conversation has nothing unread to count"
      assert_equal({ dm.id => 1 }, inbox.unread_counts)
    end

    test "a thread whose only message was deleted stays listed as a tombstone, or goes when the row is gone" do
      conversation = chatting(@bob)
      conversation.last_message.soft_delete!
      assert_equal [conversation], Chats::Inbox.for(@alice).rows, "a tombstone is still a message"

      Chats.config.deletion = :hard
      other = chatting(@carol)
      other.messages.sole.soft_delete!
      assert_not_includes Chats::Inbox.for(@alice).rows, other.reload,
                          "a hard delete heals the pointer, and an empty thread is not listed"
    end

    # --- stacking -------------------------------------------------------------

    test "conversations with a grouped counterpart fold into one row" do
      three = Array.new(3) do |index|
        listing = create_listing(title: "Listing #{index}")
        conversation = @alice.chat_with(@desk, about: listing)
        @desk.message!(conversation, "ticket #{index}")
        conversation
      end
      ordinary = chatting(@bob)

      rows = Chats::Inbox.for(@alice).rows
      group = rows.find { |row| row.is_a?(Chats::InboxGroup) }

      assert_equal 2, rows.size, "three desk threads + one DM = two rows"
      assert_includes rows, ordinary
      assert_equal @desk, group.messager
      assert_equal 3, group.open_count
      assert_equal 3, group.unread_count, "the badge aggregates the whole stack"
      assert_equal three.last, group.conversation, "freshest thread leads the stack"
      assert_equal three.last.last_message, group.last_message
      assert_not group.single?
    end

    test "the stack sorts among the other rows by its freshest activity" do
      desk_thread = @alice.chat_with(@desk)
      @desk.message!(desk_thread, "old")
      dm = @alice.chat_with(@bob)
      @bob.message!(dm, "newer")

      assert_equal([dm, desk_thread], Chats::Inbox.for(@alice).rows.map do |row|
        row.is_a?(Chats::InboxGroup) ? row.conversation : row
      end)

      @desk.message!(desk_thread, "newest")

      assert_instance_of Chats::InboxGroup, Chats::Inbox.for(@alice).rows.first
    end

    test "a stack of one still stacks — and knows it" do
      conversation = @alice.chat_with(@desk)
      @desk.message!(conversation, "just the one")

      group = Chats::Inbox.for(@alice).rows.first

      assert_instance_of Chats::InboxGroup, group
      assert group.single?
      assert_equal conversation, group.conversation
      assert_equal 1, group.unread_count
    end

    test "only DIRECT conversations stack" do
      group_chat = chatting(@bob, @desk, title: "Trip")

      assert_equal [group_chat], Chats::Inbox.for(@alice).rows
    end

    test "the viewer's own stacking never applies to their own inbox" do
      # The desk is grouped, but from the DESK's seat the counterparts are
      # ordinary users — so its own inbox is flat.
      chatting(@desk, from: @alice)
      chatting(@desk, from: @bob)

      assert_equal 2, Chats::Inbox.for(@desk).rows.size
      assert_empty Chats::Inbox.for(@desk).rows.grep(Chats::InboxGroup)
    end

    test "unread_count is stack-aware while unread_chats_count is not" do
      2.times do |index|
        conversation = @alice.chat_with(@desk, about: create_listing(title: "L#{index}"))
        @desk.message!(conversation, "ping")
      end
      dm = @alice.chat_with(@bob)
      @bob.message!(dm, "ping")

      assert_equal 2, Chats::Inbox.for(@alice).unread_count, "one stack + one DM = two rows to deal with"
      assert_equal 3, @alice.unread_chats_count, "the plain count still counts conversations"
    end

    # --- the ?with= filter ----------------------------------------------------

    test "filtering by counterpart lists that stack's conversations individually" do
      stack = Array.new(2) do |index|
        chatting(@desk, about: create_listing(title: "L#{index}"))
      end
      chatting(@bob)

      inbox = Chats::Inbox.for(@alice, with: @desk)

      assert inbox.filtered?
      assert_equal stack.reverse, inbox.rows
      assert_empty inbox.rows.grep(Chats::InboxGroup)
    end

    test "filtering by a counterpart with nothing shared is empty, never everything" do
      chatting(@bob)

      assert_empty Chats::Inbox.for(@alice, with: @desk).rows
    end

    test "the inbox_with sgid round-trips and is purpose-scoped" do
      sgid = Chats.inbox_with_sgid(@desk)

      assert_equal @desk, GlobalID::Locator.locate_signed(sgid, for: :chats_inbox_with)
      assert_nil GlobalID::Locator.locate_signed(sgid, for: :chats_recipient)
    end

    # --- limit, scope, search -------------------------------------------------

    test "inbox_limit caps the window and defaults to 200" do
      assert_equal 200, Chats.config.inbox_limit

      3.times { |index| chatting(create_user(name: "P#{index}")) }
      Chats.config.inbox_limit = 2

      assert_equal 2, Chats::Inbox.for(@alice).rows.size
    end

    test "inbox_limit must be positive" do
      Chats.config.inbox_limit = 0
      assert_raises(Chats::ConfigurationError) { Chats.config.validate! }
    end

    test "inbox_scope composes into the query" do
      kept = chatting(@bob, about: create_listing(title: "Kept"))
      chatting(@carol)

      seen = []
      Chats.config.inbox_scope = lambda { |relation, viewer|
        seen << viewer
        relation.where.not(subject_id: nil)
      }

      assert_equal [kept], Chats::Inbox.for(@alice).rows
      assert_equal [@alice], seen
    end

    test "inbox_scope is the one rule: the inbox relation, the unread count and the inbox agree" do
      kept = @alice.chat_with(@bob, about: create_listing(title: "Kept"))
      hidden = @alice.chat_with(@carol)
      @bob.message!(kept, "in the inbox")
      @carol.message!(hidden, "scoped out")

      Chats.config.inbox_scope = ->(relation, _viewer) { relation.where.not(subject_id: nil) }

      assert_equal [kept], @alice.chats.to_a
      assert_equal 1, @alice.unread_chats_count, "a conversation the scope hides must not count as unread"
      assert_equal [kept], Chats::Inbox.for(@alice).rows
    end

    test "inbox_scope and a host's own chats override reach the stacks, the filtered view and search" do
      threads = Array.new(3) do |index|
        conversation = @alice.chat_with(@desk, about: create_listing(title: "Madrid #{index}"))
        @desk.message!(conversation, "ticket #{index}")
        conversation
      end
      scoped_out, overridden_out, kept = threads
      Chats.config.inbox_scope = ->(relation, _viewer) { relation.where.not(id: scoped_out.id) }
      # A host narrowing its own inbox further, the way an app does in its model.
      @alice.define_singleton_method(:chats) { super().where.not(id: overridden_out.id) }

      group = Chats::Inbox.for(@alice).rows.sole
      assert_equal 1, group.open_count, "the stack counts only what the inbox shows"
      assert_equal 1, group.unread_count
      assert_equal [kept], group.conversations

      assert_equal [kept], Chats::Inbox.for(@alice, with: @desk).rows
      assert_equal [kept], Chats::Inbox.for(@alice, query: "madrid").rows.sole.conversations
      assert_equal 1, @alice.unread_chats_count
    end

    test "inbox_scope must be callable" do
      assert_raises(Chats::ConfigurationError) { Chats.config.inbox_scope = :not_callable }
    end

    test "search still filters by body and metadata, and searches inside stacks" do
      hit = chatting(@desk, about: create_listing(title: "Madrid → Barcelona"))
      miss = @alice.chat_with(@bob)
      @bob.message!(miss, "unrelated")

      rows = Chats::Inbox.for(@alice, query: "madrid").rows

      assert_equal 1, rows.size
      assert_equal [hit], rows.first.conversations
    end

    test "conversations stays a relation in the simple case, for ejected inboxes" do
      chatting(@bob)

      conversations = Chats::Inbox.for(@alice).conversations

      assert_kind_of ActiveRecord::Relation, conversations, "an ejected 0.1.x inbox may still chain onto it"
      assert conversations.loaded?, "and it must already be loaded — no second query to render"
      assert_equal 0, conversations.where(kind: "group").count
    end

    test "conversations becomes an Array once rows are assembled in Ruby" do
      chatting(@desk)
      chatting(@bob)

      assert_kind_of Array, Chats::Inbox.for(@alice).conversations
      assert_kind_of Array, Chats::Inbox.for(@alice, query: "bob").conversations
    end

    test "rows are ordered at full precision and tie-break on id" do
      at = Time.current.change(usec: 500_000) # a clean microsecond, so the bump below survives the DB
      first = chatting(@bob)
      second = chatting(@carol)
      # Identical timestamps: the order must still be total and repeatable.
      [first, second].each { |c| c.update_columns(last_message_at: at, updated_at: at) }

      rows = Chats::Inbox.for(@alice).rows
      assert_equal rows, Chats::Inbox.for(@alice).rows, "the same inbox must not shuffle between renders"
      assert_equal [second, first], rows, "newest id first when the timestamps tie"

      # A microsecond apart must NOT collapse into a tie (Rational, so the
      # bump is exact rather than a float that rounds away).
      first.update_columns(last_message_at: at + Rational(1, 1_000_000))
      assert_equal [first, second], Chats::Inbox.for(@alice).rows
    end

    # --- inbox_limit bounds ROWS ----------------------------------------------

    test "a deep stack never evicts ordinary conversations from the inbox" do
      personal = @alice.chat_with(@bob)
      @bob.message!(personal, "hello!")
      5.times do |index|
        conversation = @alice.chat_with(@desk, about: create_listing(title: "L#{index}"))
        @desk.message!(conversation, "ticket #{index}")
      end
      Chats.config.inbox_limit = 3

      rows = Chats::Inbox.for(@alice).rows

      assert_includes rows, personal, "a busy desk must never push a friend out of the inbox"
      assert_equal 2, rows.size, "one stack + one conversation"
    end

    test "a stack's counts are GLOBAL, not the loaded window" do
      5.times do |index|
        conversation = @alice.chat_with(@desk, about: create_listing(title: "L#{index}"))
        @desk.message!(conversation, "ticket #{index}")
      end
      Chats.config.inbox_limit = 2

      group = Chats::Inbox.for(@alice).rows.grep(Chats::InboxGroup).first

      assert_equal 5, group.open_count, "the row speaks for the whole stack"
      assert_equal 5, group.unread_count
      assert_operator group.conversations.size, :<=, 2, "but only a bounded window is loaded"
      assert_not group.single?
    end

    test "inbox_limit still bounds the rows themselves" do
      4.times { |index| chatting(create_user(name: "P#{index}")) }
      Chats.config.inbox_limit = 2

      assert_equal 2, Chats::Inbox.for(@alice).rows.size
    end

    test "the inbox query count does not grow with the inbox, or with stack depth" do
      3.times { |index| chatting(create_user(name: "P#{index}")) }
      3.times { |index| chatting(@desk, about: create_listing(title: "L#{index}")) }
      shallow = count_inbox_queries

      7.times { |index| chatting(create_user(name: "Q#{index}")) }
      12.times { |index| chatting(@desk, about: create_listing(title: "D#{index}")) }
      deep = count_inbox_queries

      assert_equal shallow, deep, "the inbox must not go N+1 as it grows"
      # Two legs (ordinary + stacked) with their preloads, one grouped
      # unread-count query, and two aggregates for the one stack.
      assert_operator deep, :<=, 14, "and it must stay a small, fixed budget"
    end

    test "several stacks cost the same queries as one, and each counts only itself" do
      desks = Array.new(2) { |index| create_desk(name: "Desk #{index}") }
      desks.each_with_index do |desk, index|
        (index + 2).times { |n| desk.message!(@alice, "ticket #{n}", about: create_listing(title: "D#{index}-#{n}")) }
      end
      two_stacks = count_inbox_queries

      more = Array.new(3) { |index| create_desk(name: "More #{index}") }
      more.each { |desk| 4.times { |n| desk.message!(@alice, "ticket #{n}", about: create_listing(title: "M#{n}")) } }
      five_stacks = count_inbox_queries

      assert_equal two_stacks, five_stacks, "a stack's totals must not cost queries of its own"

      groups = Chats::Inbox.for(@alice).rows.grep(Chats::InboxGroup).index_by(&:messager)
      assert_equal([2, 3, 4, 4, 4], (desks + more).map { |desk| groups.fetch(desk).open_count })
      assert_equal([2, 3, 4, 4, 4], (desks + more).map { |desk| groups.fetch(desk).unread_count })
    end

    private

    # Open a conversation AND write in it — lists show only conversations
    # with a message
    # (Chats::Conversation.with_messages). The opener writes, so nothing is
    # unread for them.
    def chatting(*others, from: @alice, **options)
      conversation = from.chat_with(*others, **options)
      from.message!(conversation, "hi")
      conversation
    end

    def count_inbox_queries
      queries = 0
      counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }

      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        inbox = Chats::Inbox.for(@alice)
        inbox.rows.each { |row| row.is_a?(Chats::InboxGroup) ? row.unread_count : inbox.unread_count_for(row) }
        inbox.unread_count
      end

      queries
    end
  end
end
