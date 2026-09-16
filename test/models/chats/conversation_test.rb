# frozen_string_literal: true

require "test_helper"

module Chats
  class ConversationTest < ActiveSupport::TestCase
    setup do
      @alice = create_user(name: "Alice")
      @bob = create_user(name: "Bob")
      @carol = create_user(name: "Carol")
    end

    # --- direct_between! -------------------------------------------------------

    test "direct_between! creates a direct conversation with both participants" do
      conversation = Conversation.direct_between!(@alice, @bob)

      assert conversation.direct?
      assert conversation.participant?(@alice)
      assert conversation.participant?(@bob)
      assert_equal 2, conversation.participants.count
    end

    test "direct_between! is idempotent — same pair, same conversation" do
      first = Conversation.direct_between!(@alice, @bob)
      second = Conversation.direct_between!(@bob, @alice) # reversed order!

      assert_equal first, second
      assert_equal 1, Conversation.count
    end

    test "direct_between! threads per-subject when about: is given" do
      listing = create_listing
      other_listing = create_listing(title: "Sevilla → Granada")

      plain = Conversation.direct_between!(@alice, @bob)
      about_one = Conversation.direct_between!(@alice, @bob, about: listing)
      about_two = Conversation.direct_between!(@alice, @bob, about: other_listing)

      assert_equal 3, Conversation.count
      assert_equal listing, about_one.subject
      assert_not_equal plain, about_one
      assert_not_equal about_one, about_two

      # ...and each is individually idempotent.
      assert_equal about_one, Conversation.direct_between!(@bob, @alice, about: listing)
    end

    test "direct_between! refuses self-conversations" do
      assert_raises(ArgumentError) { Conversation.direct_between!(@alice, @alice) }
    end

    test "direct_between! raises BlockedError for blocked pairs" do
      block_pair!(@alice, @bob)

      assert_raises(Chats::BlockedError) { Conversation.direct_between!(@alice, @bob) }
    end

    test "direct_between! honors the host can_message policy" do
      Chats.config.can_message = ->(_sender, _recipient) { false }

      assert_raises(Chats::NotAllowedError) { Conversation.direct_between!(@alice, @bob) }
    end

    test "direct_key is order-independent and unique-indexed" do
      key_ab = Conversation.direct_key_for([@alice, @bob])
      key_ba = Conversation.direct_key_for([@bob, @alice])

      assert_equal key_ab, key_ba

      Conversation.direct_between!(@alice, @bob)
      # Enforced at the DB layer (unique index), not as a model validation —
      # that's what makes create_or_find_by! race-safe. See the model comment.
      assert_raises(ActiveRecord::RecordNotUnique) do
        Conversation.create!(kind: "direct", direct_key: key_ab)
      end
    end

    test "re-finding an existing conversation heals missing participants idempotently" do
      conversation = Conversation.direct_between!(@alice, @bob)
      conversation.participants.find_by(messager: @bob).destroy!

      again = Conversation.direct_between!(@alice, @bob)
      assert_equal conversation, again
      assert again.participant?(@bob)
    end

    # --- groups ----------------------------------------------------------------

    test "group! creates a titled group with the creator as owner" do
      group = Conversation.group!(@alice, [@bob, @carol], title: "Roadtrip")

      assert group.group?
      assert_equal "Roadtrip", group.title
      assert_equal "owner", group.participant_for(@alice).role
      assert_equal "member", group.participant_for(@bob).role
      assert_equal 3, group.participants.count
    end

    test "group! requires at least two others" do
      assert_raises(ArgumentError) { Conversation.group!(@alice, [@bob]) }
    end

    test "group! respects the groups feature flag" do
      Chats.config.groups = false

      assert_raises(Chats::NotAllowedError) { Conversation.group!(@alice, [@bob, @carol]) }
    end

    test "group! respects the can_create_group policy" do
      Chats.config.can_create_group = ->(_creator) { false }

      assert_raises(Chats::NotAllowedError) { Conversation.group!(@alice, [@bob, @carol]) }
    end

    test "add_participant! re-joins someone who left, keeping their read state" do
      group = Conversation.group!(@alice, [@bob, @carol])
      participant = group.participant_for(@bob)
      participant.read!
      horizon = participant.reload.last_read_at
      participant.leave!

      rejoined = group.add_participant!(@bob)
      assert rejoined.active?
      assert_equal horizon, rejoined.last_read_at
    end

    # --- naming ----------------------------------------------------------------

    test "counterpart_for names the other side of a direct thread, from either seat" do
      conversation = conversation_between(@alice, @bob)

      assert_equal @bob, conversation.counterpart_for(@alice)
      assert_equal @alice, conversation.counterpart_for(@bob)
    end

    test "counterpart_for is nil for a group and for a thread whose other seat left" do
      group = Conversation.group!(@alice, [@bob, @carol], title: "Roadtrip")
      assert_nil group.counterpart_for(@alice)

      direct = conversation_between(@alice, @bob)
      direct.participant_for(@bob).leave!

      assert_nil Conversation.find(direct.id).counterpart_for(@alice)
    end

    test "counterpart_for resolves once per viewer, however often a row asks" do
      conversation = conversation_between(@alice, @bob)
      conversation.counterpart_for(@alice)

      # An inbox row asks for the title, the avatar and the badge. That must
      # stay ONE query, the way it was before the badge existed — so after
      # the first resolution, none of them go back to the database.
      statements = capture_sql do
        assert_equal @bob, conversation.counterpart_for(@alice)
        assert_equal "Bob", conversation.title_for(@alice)
      end

      assert_empty statements,
                   "the counterpart is memoized per viewer, so a row resolves it once: #{statements.inspect}"
    end

    test "title_for names direct threads after the counterpart" do
      conversation = conversation_between(@alice, @bob)

      assert_equal "Bob", conversation.title_for(@alice)
      assert_equal "Alice", conversation.title_for(@bob)
    end

    test "title_for uses the group title, falling back to member names" do
      titled = Conversation.group!(@alice, [@bob, @carol], title: "Roadtrip")
      untitled = Conversation.group!(@alice, [@bob, @carol])

      assert_equal "Roadtrip", titled.title_for(@alice)
      assert_includes untitled.title_for(@alice), "Bob"
    end

    test "subject_label comes from the subject's chat_subject_label" do
      listing = create_listing(title: "Madrid → Valencia")
      conversation = conversation_between(@alice, @bob, about: listing)

      assert_equal "Madrid → Valencia", conversation.subject_label
      assert_nil conversation_between(@alice, @carol).subject_label
    end

    # --- inbox -----------------------------------------------------------------

    test "inbox_for lists active conversations, newest activity first" do
      older = conversation_between(@alice, @bob)
      newer = conversation_between(@alice, @carol)
      older.messages.create!(sender: @bob, body: "hi", created_at: 1.hour.ago)
      newer.messages.create!(sender: @carol, body: "hello")

      assert_equal [newer, older], Conversation.inbox_for(@alice).to_a
    end

    test "inbox_for excludes conversations the messager left" do
      group = Conversation.group!(@alice, [@bob, @carol])
      group.participant_for(@alice).leave!

      assert_not_includes Conversation.inbox_for(@alice), group
      assert_includes Conversation.inbox_for(@bob), group
    end

    test "inbox_for hides direct threads with blocked counterparts but keeps groups" do
      direct = conversation_between(@alice, @bob)
      group = Conversation.group!(@alice, [@bob, @carol])
      block_pair!(@alice, @bob)

      inbox = Conversation.inbox_for(@alice)
      assert_not_includes inbox, direct
      assert_includes inbox, group

      # Lift the block — the thread reappears (nothing was deleted).
      Chats.config.blocked_messager_ids = ->(_messager) { [] }
      assert_includes Conversation.inbox_for(@alice), direct
    end

    # --- unread ----------------------------------------------------------------

    test "unread_by finds conversations with foreign unread messages only" do
      conversation = conversation_between(@alice, @bob)
      assert_empty Conversation.inbox_for(@alice).unread_by(@alice)

      conversation.messages.create!(sender: @alice, body: "own message doesn't count")
      assert_empty Conversation.inbox_for(@alice).unread_by(@alice)

      conversation.messages.create!(sender: @bob, body: "this one does")
      assert_includes Conversation.inbox_for(@alice).unread_by(@alice), conversation

      conversation.mark_read_by!(@alice)
      assert_empty Conversation.inbox_for(@alice).unread_by(@alice)
    end

    test "unread_counts_for batches per-conversation counts in one query" do
      one = conversation_between(@alice, @bob)
      two = conversation_between(@alice, @carol)
      one.messages.create!(sender: @bob, body: "1")
      one.messages.create!(sender: @bob, body: "2")
      two.messages.create!(sender: @carol, body: "3")

      counts = Conversation.unread_counts_for(@alice, [one, two])
      assert_equal 2, counts[one.id]
      assert_equal 1, counts[two.id]
      assert_equal({}, Conversation.unread_counts_for(@alice, []))
    end

    # --- system messages & denormalization --------------------------------------

    test "post_system_message! creates a senderless system message" do
      conversation = conversation_between(@alice, @bob)
      message = conversation.post_system_message!("Ride cancelled")

      assert message.system?
      assert_nil message.sender
      assert_equal "Ride cancelled", message.body
    end

    test "messages maintain last_message pointers and counter cache" do
      conversation = conversation_between(@alice, @bob)
      first = conversation.messages.create!(sender: @alice, body: "first")
      last = conversation.messages.create!(sender: @bob, body: "last")

      conversation.reload
      assert_equal last, conversation.last_message
      assert_equal last.created_at.to_i, conversation.last_message_at.to_i
      assert_equal 2, conversation.messages_count

      last.destroy!
      conversation.reload
      assert_equal first, conversation.last_message
      assert_equal 1, conversation.messages_count
    end

    # --- moderation contract ------------------------------------------------------

    test "exposes the moderation duck-typed contract" do
      group = Conversation.group!(@alice, [@bob, @carol], title: "Spam group")

      assert_equal @alice, group.reported_owner
      assert_equal "Spam group", group.moderation_snapshot(:title)
      assert group.removable_reported_field?(:title)
      assert group.report_visible_to?(@bob, field: :title)
      refute group.report_visible_to?(create_user, field: :title)
      assert_equal "group", group.moderation_content_type

      assert group.remove_reported_field!(:title)
      assert_nil group.reload.title
      refute group.remove_reported_field!(:something_else)
    end
  end
end
