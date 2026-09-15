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

    # --- stacking -------------------------------------------------------------

    test "conversations with a grouped counterpart fold into one row" do
      three = Array.new(3) do |index|
        listing = create_listing(title: "Listing #{index}")
        conversation = @alice.chat_with(@desk, about: listing)
        @desk.message!(conversation, "ticket #{index}")
        conversation
      end
      ordinary = @alice.chat_with(@bob)

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
      group_chat = @alice.chat_with(@bob, @desk, title: "Trip")

      assert_equal [group_chat], Chats::Inbox.for(@alice).rows
    end

    test "the viewer's own stacking never applies to their own inbox" do
      # The desk is grouped, but from the DESK's seat the counterparts are
      # ordinary users — so its own inbox is flat.
      @alice.chat_with(@desk)
      @bob.chat_with(@desk)

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
        @alice.chat_with(@desk, about: create_listing(title: "L#{index}"))
      end
      @alice.chat_with(@bob)

      inbox = Chats::Inbox.for(@alice, with: @desk)

      assert inbox.filtered?
      assert_equal stack.reverse, inbox.rows
      assert_empty inbox.rows.grep(Chats::InboxGroup)
    end

    test "filtering by a counterpart with nothing shared is empty, never everything" do
      @alice.chat_with(@bob)

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

      3.times { |index| @alice.chat_with(create_user(name: "P#{index}")) }
      Chats.config.inbox_limit = 2

      assert_equal 2, Chats::Inbox.for(@alice).rows.size
    end

    test "inbox_limit must be positive" do
      Chats.config.inbox_limit = 0
      assert_raises(Chats::ConfigurationError) { Chats.config.validate! }
    end

    test "inbox_scope composes into the query" do
      kept = @alice.chat_with(@bob, about: create_listing(title: "Kept"))
      @alice.chat_with(@carol)

      seen = []
      Chats.config.inbox_scope = lambda { |relation, viewer|
        seen << viewer
        relation.where.not(subject_id: nil)
      }

      assert_equal [kept], Chats::Inbox.for(@alice).rows
      assert_equal [@alice], seen
    end

    test "inbox_scope must be callable" do
      assert_raises(Chats::ConfigurationError) { Chats.config.inbox_scope = :not_callable }
    end

    test "search still filters by body and metadata, and searches inside stacks" do
      hit = @alice.chat_with(@desk, about: create_listing(title: "Madrid → Barcelona"))
      miss = @alice.chat_with(@bob)
      @bob.message!(miss, "unrelated")

      rows = Chats::Inbox.for(@alice, query: "madrid").rows

      assert_equal 1, rows.size
      assert_equal [hit], rows.first.conversations
    end

    test "the inbox runs a constant number of queries regardless of row count" do
      5.times { |index| @alice.chat_with(create_user(name: "P#{index}")) }
      3.times { |index| @alice.chat_with(@desk, about: create_listing(title: "L#{index}")) }

      queries = 0
      counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }

      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        inbox = Chats::Inbox.for(@alice)
        inbox.rows.each { |row| row.is_a?(Chats::InboxGroup) ? row.unread_count : inbox.unread_count_for(row) }
        inbox.unread_count
      end

      # conversations + last_messages + subjects + participants + messagers
      # + ONE grouped unread-count query. No per-row follow-ups.
      assert_operator queries, :<=, 7, "the inbox must not go N+1 when it stacks"
    end
  end
end
