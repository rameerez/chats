# frozen_string_literal: true

require "test_helper"

module Chats
  class MessageTest < ActiveSupport::TestCase
    setup do
      @alice = create_user(name: "Alice")
      @bob = create_user(name: "Bob")
      @conversation = conversation_between(@alice, @bob)
    end

    # --- validations -------------------------------------------------------------

    test "a text message needs a sender" do
      message = @conversation.messages.new(body: "hello")

      assert_not message.valid?
      assert message.errors[:sender].any?
    end

    test "a message needs a body (or attachments)" do
      message = @conversation.messages.new(sender: @alice)

      assert_not message.valid?
      assert message.errors[:body].any?
    end

    test "an attachments-only message is valid" do
      message = @conversation.messages.new(sender: @alice)
      message.files.attach(io: StringIO.new(PNG_BYTES), filename: "pic.png", content_type: "image/png")

      assert message.valid?, message.errors.full_messages.to_sentence
    end

    test "body length is capped by configuration" do
      Chats.config.max_message_length = 10
      message = @conversation.messages.new(sender: @alice, body: "x" * 11)

      assert_not message.valid?
      assert message.errors[:body].any?

      Chats.config.max_message_length = nil
      assert @conversation.messages.new(sender: @alice, body: "x" * 11).valid?
    end

    test "only participants can send" do
      outsider = create_user
      message = @conversation.messages.new(sender: outsider, body: "let me in")

      assert_not message.valid?
      assert message.errors[:sender].any?
    end

    test "someone who left a group can't send into it" do
      carol = create_user
      group = Conversation.group!(@alice, [@bob, carol])
      group.participant_for(carol).leave!

      message = group.messages.new(sender: carol, body: "still here?")
      assert_not message.valid?
    end

    test "a block placed mid-conversation stops the next send in direct threads" do
      @conversation.messages.create!(sender: @alice, body: "before the block")
      block_pair!(@alice, @bob)

      message = @conversation.messages.new(sender: @alice, body: "after the block")
      assert_not message.valid?
      assert message.errors[:base].any?
    end

    test "blocks do not gag group conversations" do
      carol = create_user
      group = Conversation.group!(@alice, [@bob, carol])
      block_pair!(@alice, @bob)

      assert group.messages.new(sender: @alice, body: "group still works").valid?
    end

    test "system messages need a body but no sender" do
      assert @conversation.messages.new(kind: "system", body: "Ride cancelled").valid?
      assert_not @conversation.messages.new(kind: "system").valid?
    end

    # --- attachments policy ----------------------------------------------------------

    test "attachments can be disabled entirely" do
      Chats.config.attachments = false
      message = @conversation.messages.new(sender: @alice, body: "with file")
      message.files.attach(io: StringIO.new(PNG_BYTES), filename: "pic.png", content_type: "image/png")

      assert_not message.valid?
      assert message.errors[:files].any?
    end

    test "images-only mode rejects non-images" do
      Chats.config.attachments = :images
      message = @conversation.messages.new(sender: @alice, body: "with file")
      message.files.attach(io: StringIO.new("plain text"), filename: "notes.txt", content_type: "text/plain")

      assert_not message.valid?

      Chats.config.attachments = :any
      assert message.valid?
    end

    test "attachment count and size limits apply" do
      Chats.config.max_attachments_per_message = 1
      message = @conversation.messages.new(sender: @alice, body: "two files")
      2.times do |i|
        message.files.attach(io: StringIO.new(PNG_BYTES), filename: "pic#{i}.png", content_type: "image/png")
      end
      assert_not message.valid?

      Chats.config.max_attachments_per_message = 4
      Chats.config.max_attachment_size = 10 # bytes — the PNG is bigger
      small = @conversation.messages.new(sender: @alice, body: "big file")
      small.files.attach(io: StringIO.new(PNG_BYTES), filename: "pic.png", content_type: "image/png")
      assert_not small.valid?
    end

    # --- editing & deleting -----------------------------------------------------------

    test "edit! updates the body and stamps edited_at" do
      message = @conversation.messages.create!(sender: @alice, body: "typo")
      message.edit!("fixed")

      assert_equal "fixed", message.reload.body
      assert message.edited?
    end

    test "edit! refuses when editing is disabled or the message is deleted" do
      message = @conversation.messages.create!(sender: @alice, body: "hello")

      Chats.config.editing = false
      assert_raises(Chats::NotAllowedError) { message.edit!("nope") }

      Chats.config.editing = true
      message.soft_delete!
      assert_raises(Chats::NotAllowedError) { message.edit!("nope") }
    end

    test "soft delete tombstones: clears body, purges files, keeps the row" do
      message = @conversation.messages.create!(sender: @alice, body: "regrettable")
      message.files.attach(io: StringIO.new(PNG_BYTES), filename: "pic.png", content_type: "image/png")

      assert message.soft_delete!
      message.reload
      assert message.deleted?
      assert_nil message.body
      assert_nil message.visible_body
      assert_equal 1, Message.count
    end

    test "deletion :hard destroys the row, false disables deletion" do
      message = @conversation.messages.create!(sender: @alice, body: "gone")

      Chats.config.deletion = :hard
      assert message.soft_delete!
      assert_equal 0, Message.count

      survivor = @conversation.messages.create!(sender: @alice, body: "stays")
      Chats.config.deletion = false
      assert_equal false, survivor.soft_delete!
      assert_equal 1, Message.count
    end

    # --- read state ----------------------------------------------------------------

    test "read_by? derives from the participant read horizon" do
      message = @conversation.messages.create!(sender: @alice, body: "seen?")

      refute message.read_by?(@bob)
      @conversation.mark_read_by!(@bob)
      assert message.read_by?(@bob)
    end

    # --- pagination -------------------------------------------------------------------

    test "before_message keyset-paginates without skipping or duplicating" do
      messages = 5.times.map { |i| @conversation.messages.create!(sender: @alice, body: "m#{i}") }

      page = @conversation.messages.before_message(messages[3]).recent_first.to_a
      assert_equal [messages[2], messages[1], messages[0]], page
    end

    # --- notifier hook -------------------------------------------------------------------

    test "fires :message_created through the notifier for human messages" do
      events = []
      Chats.config.notifier = ->(event, **payload) { events << [event, payload[:message]] }

      message = @conversation.messages.create!(sender: @alice, body: "ping")

      assert_equal [[:message_created, message]], events
    end

    test "system messages do not notify (the host posted them itself)" do
      events = []
      Chats.config.notifier = ->(event, **) { events << event }

      @conversation.post_system_message!("Ride cancelled")

      assert_empty events
    end

    # --- misc ------------------------------------------------------------------------------

    test "metadata defaults to an empty hash" do
      message = @conversation.messages.create!(sender: @alice, body: "meta")
      assert_equal({}, message.metadata)
    end

    test "sender_key identifies the sender stably" do
      message = @conversation.messages.create!(sender: @alice, body: "key")
      assert_equal Chats.messager_key(@alice), message.sender_key
      assert_nil @conversation.post_system_message!("note").sender_key
    end

    # --- moderation contract ------------------------------------------------------------------

    test "exposes the moderation duck-typed contract" do
      message = @conversation.messages.create!(sender: @alice, body: "reportable")

      assert_equal @alice, message.reported_owner
      assert_equal "reportable", message.moderation_snapshot(:body)
      assert_nil message.moderation_snapshot(:other)
      assert message.removable_reported_field?(:body)
      assert_equal "message", message.moderation_content_type

      # Only other participants can report it — not the author, not outsiders.
      assert message.report_visible_to?(@bob, field: :body)
      refute message.report_visible_to?(@alice, field: :body)
      refute message.report_visible_to?(create_user, field: :body)

      # A moderator removing the body == the tombstone path.
      assert message.remove_reported_field!(:body)
      assert message.reload.deleted?
    end

    test "moderation_field_value and change detection cover the files seam" do
      message = @conversation.messages.create!(sender: @alice, body: "with file")
      assert_equal "with file", message.moderation_field_value(:body)

      message.files.attach(io: StringIO.new(PNG_BYTES), filename: "pic.png", content_type: "image/png")
      message.save!
      assert message.moderation_field_changed_for_commit?(:files)
      assert_equal message.files, message.moderation_field_value(:files)
    end
  end
end
