# frozen_string_literal: true

require "test_helper"

module Chats
  # The SUBJECT owns whether its conversation still takes messages
  # (Chats::ChatSubject#chat_locked?). Reading is never affected: a locked
  # thread keeps all of its history, it just stops accepting new writes.
  class LockedConversationTest < ActiveSupport::TestCase
    setup do
      @alice = create_user(name: "Alice")
      @bob = create_user(name: "Bob")
      @listing = create_listing(title: "Madrid → Barcelona")
      @conversation = @alice.chat_with(@bob, about: @listing)
    end

    test "the default subject contract is unlocked and silent" do
      plain = Class.new(ApplicationRecord) do
        def self.name = "PlainSubject"
        self.table_name = "listings"
        acts_as_chat_subject
      end

      assert_not plain.new(title: "untouched").chat_locked?
      assert_nil plain.new(title: "untouched").chat_locked_notice
    end

    test "a subjectless conversation is never locked" do
      assert_not @alice.chat_with(@bob).locked?
    end

    test "locked? and locked_notice follow the subject" do
      assert_not @conversation.locked?
      assert_nil @conversation.locked_notice

      @listing.update!(locked: true)

      assert @conversation.reload.locked?
      assert_equal "This listing is closed.", @conversation.locked_notice
    end

    test "locked_notice falls back to the gem's own sentence" do
      @listing.update!(locked: true)
      @listing.stub(:chat_locked_notice, nil) do
        @conversation.subject = @listing
        assert_equal I18n.t("chats.composer.locked"), @conversation.locked_notice
      end
    end

    test "a locked conversation refuses text messages with the :locked error" do
      @listing.update!(locked: true)

      message = @conversation.messages.new(sender: @alice, body: "still trying")

      assert_not message.valid?
      assert message.errors.of_kind?(:base, :locked)
      assert_equal I18n.t("activerecord.errors.models.chats/message.attributes.base.locked"),
                   message.errors.full_messages.first
      assert_raises(ActiveRecord::RecordInvalid) { @alice.message!(@conversation, "nope") }
    end

    test "system messages are exempt — the app can always explain the lock" do
      @listing.update!(locked: true)

      message = @conversation.post_system_message!("This listing was closed")

      assert message.persisted?
      assert message.system?
    end

    test "locking never touches history or reading" do
      said = @alice.message!(@conversation, "before the lock")
      @listing.update!(locked: true)

      assert_equal [said], @conversation.reload.messages.to_a
      assert_equal said, @conversation.last_message
      assert_includes @bob.chats, @conversation
      # And editing an existing message still works: the lock gates NEW writes.
      assert said.edit!("before the lock (fixed)")
    end

    test "unlocking restores sending" do
      @listing.update!(locked: true)
      @listing.update!(locked: false)

      assert @alice.message!(@conversation.reload, "back open").persisted?
    end
  end
end
