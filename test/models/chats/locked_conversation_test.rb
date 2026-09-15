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
    end

    # --- the lock gates EVERY write, not just creation ------------------------

    test "editing a message in a locked conversation raises LockedError" do
      said = @alice.message!(@conversation, "before the lock")
      @listing.update!(locked: true)

      error = assert_raises(Chats::LockedError) { said.edit!("sneaking an edit in") }
      assert_equal "This listing is closed.", error.message
      assert_equal @conversation, error.conversation
      assert_equal "before the lock", said.reload.body
    end

    test "deleting a message in a locked conversation raises LockedError" do
      said = @alice.message!(@conversation, "before the lock")
      @listing.update!(locked: true)

      assert_raises(Chats::LockedError) { said.soft_delete! }
      assert_not said.reload.deleted?
    end

    test "reacting in a locked conversation raises LockedError, both ways" do
      said = @alice.message!(@conversation, "before the lock")
      Chats::Reaction.toggle!(message: said, reactor: @bob, emoji: "👍")
      @listing.update!(locked: true)

      assert_raises(Chats::LockedError) { Chats::Reaction.toggle!(message: said, reactor: @alice, emoji: "🙏") }
      # And taking an existing one back is a write too.
      assert_raises(Chats::LockedError) { Chats::Reaction.toggle!(message: said, reactor: @bob, emoji: "👍") }
      assert_equal [["👍", 1]], Chats::Reaction.summary_for(said)
    end

    test "LockedError is a NotAllowedError, so hosts rescuing the old class still catch it" do
      assert_operator Chats::LockedError, :<, Chats::NotAllowedError
    end

    test "moderation outranks the lock — reported content is always removable" do
      said = @alice.message!(@conversation, "reported content")
      @listing.update!(locked: true)

      assert said.remove_reported_field!("body")
      assert said.reload.deleted?
      assert_nil said.body
    end

    test "system messages stay writable on every path" do
      @listing.update!(locked: true)

      system_message = @conversation.post_system_message!("This listing was closed")
      assert_nothing_raised { system_message.edit!("This listing was closed (edited by the app)") }
      # A system message can't be soft-deleted at all (it would fail its own
      # body-presence rule) — but the LOCK must not be what stops it.
      error = assert_raises(ActiveRecord::RecordInvalid) { system_message.soft_delete! }
      assert_not_kind_of Chats::LockedError, error
    end

    test "unlocking restores sending" do
      @listing.update!(locked: true)
      @listing.update!(locked: false)

      assert @alice.message!(@conversation.reload, "back open").persisted?
    end
  end
end
