# frozen_string_literal: true

require "test_helper"

module Chats
  class ParticipantTest < ActiveSupport::TestCase
    setup do
      @alice = create_user(name: "Alice")
      @bob = create_user(name: "Bob")
      @conversation = conversation_between(@alice, @bob)
      @participant = @conversation.participant_for(@alice)
    end

    test "one seat per messager per conversation (DB-enforced)" do
      # The unique index is the enforcement (create_or_find_by! depends on
      # it) — see the model comment.
      assert_raises(ActiveRecord::RecordNotUnique) do
        @conversation.participants.create!(messager: @alice)
      end
    end

    test "unread_count counts foreign visible messages past the horizon" do
      assert_equal 0, @participant.unread_count

      @conversation.messages.create!(sender: @alice, body: "own — never unread")
      @conversation.messages.create!(sender: @bob, body: "unread 1")
      tombstoned = @conversation.messages.create!(sender: @bob, body: "unread then deleted")
      tombstoned.soft_delete!

      assert_equal 1, @participant.reload.unread_count
      assert @participant.unread?
    end

    test "system messages count as unread for everyone" do
      @conversation.post_system_message!("Ride cancelled")

      assert_equal 1, @participant.unread_count
      assert_equal 1, @conversation.participant_for(@bob).unread_count
    end

    test "read! advances the horizon monotonically" do
      @conversation.messages.create!(sender: @bob, body: "hey")
      @participant.read!
      horizon = @participant.reload.last_read_at
      assert_equal 0, @participant.unread_count

      # A stale (earlier) read never moves the horizon backwards.
      @participant.read!(at: 1.hour.ago)
      assert_equal horizon, @participant.reload.last_read_at
    end

    test "mute! and leave! flip their flags" do
      @participant.mute!
      assert @participant.muted?
      @participant.unmute!
      refute @participant.muted?

      @participant.leave!
      assert @participant.left?
      refute @participant.active?
    end

    test "groups are capped at max_group_size" do
      Chats.config.max_group_size = 3
      group = Conversation.group!(@alice, [@bob, create_user])

      overflow = group.participants.new(messager: create_user)
      assert_not overflow.valid?
      assert overflow.errors[:base].any?
    end

    test "direct conversations ignore the group size cap" do
      Chats.config.max_group_size = 3
      # Already has 2 participants; a (hypothetical) third seat in a direct
      # thread isn't blocked by the GROUP cap — direct threads simply never
      # grow through any public API.
      extra = @conversation.participants.new(messager: create_user)
      assert extra.valid?
    end

    # --- notification etiquette ---------------------------------------------------

    test "notifiable_for? excludes the sender, the muted, and the departed" do
      message = @conversation.messages.create!(sender: @bob, body: "ping")

      assert @participant.notifiable_for?(message)
      refute @conversation.participant_for(@bob).notifiable_for?(message)

      @participant.mute!
      refute @participant.notifiable_for?(message)
      @participant.unmute!

      @participant.leave!
      refute @participant.notifiable_for?(message)
    end

    test "should_notify? fires once per unread burst" do
      @conversation.messages.create!(sender: @bob, body: "first")
      assert @participant.should_notify?

      @participant.mark_notified!
      refute @participant.should_notify? # already notified for this burst

      @conversation.messages.create!(sender: @bob, body: "second")
      refute @participant.should_notify? # still the same unread burst

      @participant.read!
      @conversation.messages.create!(sender: @bob, body: "a new burst")
      assert @participant.reload.should_notify?
    end
  end
end
