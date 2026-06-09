# frozen_string_literal: true

require "test_helper"

module Chats
  class MessagerTest < ActiveSupport::TestCase
    setup do
      @alice = create_user(name: "Alice")
      @bob = create_user(name: "Bob")
      @carol = create_user(name: "Carol")
    end

    test "chat_with one person finds-or-creates the direct thread" do
      conversation = @alice.chat_with(@bob)

      assert conversation.direct?
      assert_equal conversation, @bob.chat_with(@alice)
    end

    test "chat_with several people creates a group" do
      group = @alice.chat_with(@bob, @carol, title: "Trip")

      assert group.group?
      assert_equal "Trip", group.title
      assert_equal "owner", group.participant_for(@alice).role
    end

    test "chat_with about: threads per subject" do
      listing = create_listing

      conversation = @alice.chat_with(@bob, about: listing)
      assert_equal listing, conversation.subject
      assert_equal conversation, @alice.chat_with(@bob, about: listing)
      assert_not_equal conversation, @alice.chat_with(@bob)
    end

    test "message! DMs a messager in one line" do
      message = @alice.message!(@bob, "hola!")

      assert_equal "hola!", message.body
      assert_equal @alice, message.sender
      assert message.conversation.participant?(@bob)
    end

    test "message! posts into an existing conversation" do
      conversation = @alice.chat_with(@bob)
      message = @alice.message!(conversation, "direct into the thread")

      assert_equal conversation, message.conversation
    end

    test "message! threads by subject when about: is given" do
      listing = create_listing
      message = @alice.message!(@bob, "about the ride", about: listing)

      assert_equal listing, message.conversation.subject
    end

    test "message! raises BlockedError through the same enforcement path" do
      block_pair!(@alice, @bob)

      assert_raises(Chats::BlockedError) { @alice.message!(@bob, "should not pass") }
    end

    test "chats is the inbox relation" do
      conversation = @alice.chat_with(@bob)
      assert_includes @alice.chats, conversation
      assert_empty @carol.chats
    end

    test "unread_chats_count counts conversations, not messages" do
      one = @alice.chat_with(@bob)
      two = @alice.chat_with(@carol)
      2.times { @bob.message!(one, "ping") }
      @carol.message!(two, "pong")

      assert_equal 2, @alice.unread_chats_count
      assert @alice.unread_chats?

      one.mark_read_by!(@alice)
      assert_equal 1, @alice.unread_chats_count
    end

    test "unread_chats_count ignores blocked-hidden threads" do
      one = @alice.chat_with(@bob)
      @bob.message!(one, "soon to be blocked")
      block_pair!(@alice, @bob)

      assert_equal 0, @alice.unread_chats_count
    end

    test "destroying a messager nullifies their messages and frees history" do
      conversation = @alice.chat_with(@bob)
      message = @bob.message!(conversation, "I was here")

      @bob.destroy!

      message.reload
      assert_nil message.sender
      assert_equal "I was here", message.body
      # Bob's seat is gone with him; Alice keeps the thread.
      assert_equal 1, conversation.participants.count
    end

    test "chat_participation_in returns the seat" do
      conversation = @alice.chat_with(@bob)

      assert_equal conversation.participant_for(@alice), @alice.chat_participation_in(conversation)
    end
  end
end
