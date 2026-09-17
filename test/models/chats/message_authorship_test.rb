# frozen_string_literal: true

require "test_helper"

module Chats
  # `sender` is the SEAT a message came from; `author` is who WROTE it on
  # that seat's behalf. The distinction is what lets a shared desk answer as
  # itself while the human stays visible.
  class MessageAuthorshipTest < ActiveSupport::TestCase
    setup do
      @alice = create_user(name: "Alice")
      @lucia = create_user(name: "Lucía Gómez")
      @desk = create_desk(name: "Support")
      @conversation = @alice.chat_with(@desk)
    end

    test "messages have no author by default" do
      message = @alice.message!(@conversation, "my payout is stuck")

      assert_nil message.author
      assert_not message.signed?
      assert_not message.authored_by?(@alice)
    end

    test "a message written from another seat is signed" do
      message = @desk.message!(@conversation, "On it!", author: @lucia)

      assert_equal @desk, message.sender
      assert_equal @lucia, message.author
      assert message.signed?
      assert message.authored_by?(@lucia)
      assert_not message.authored_by?(@alice)
    end

    test "authoring from your own seat is not a signature" do
      message = @alice.message!(@conversation, "thanks!", author: @alice)

      assert_equal @alice, message.author
      assert_not message.signed?, "a message from your own seat needs no signature"
      assert message.authored_by?(@alice)
    end

    test "the author is polymorphic and survives a reload" do
      message = @desk.message!(@conversation, "On it!", author: @lucia)

      reloaded = Chats::Message.find(message.id)
      assert_equal "User", reloaded.author_type
      assert_equal @lucia, reloaded.author
    end

    test "conversation.messages.create! takes an author too" do
      message = @conversation.messages.create!(sender: @desk, body: "Hola", author: @lucia)

      assert message.signed?
    end

    test "the signature line defaults to the localized dash + display name" do
      message = @desk.message!(@conversation, "On it!", author: @lucia)

      assert_equal "— Lucía Gómez", Chats.message_signature_for(message)
      assert_nil Chats.message_signature_for(@alice.message!(@conversation, "unsigned"))
    end

    test "config.message_signature overrides the text" do
      Chats.config.message_signature = ->(message) { "escrito por #{message.author.name}" }
      message = @desk.message!(@conversation, "On it!", author: @lucia)

      assert_equal "escrito por Lucía Gómez", Chats.message_signature_for(message)
      # Still nil for unsigned messages: the hook is never asked about them.
      assert_nil Chats.message_signature_for(@alice.message!(@conversation, "unsigned"))
    end

    test "config.message_signature must be callable or nil" do
      assert_raises(Chats::ConfigurationError) { Chats.config.message_signature = "— me" }

      Chats.config.message_signature = nil
      assert_nil Chats.config.message_signature
    end

    test "a persisted author needs no messaging capabilities" do
      author = create_listing(title: "Operator identity")
      message = @desk.message!(@conversation, "On it!", author: author)
      assert_equal author, message.reload.author
      assert_not @conversation.participant?(author)
    end

    test "sending does not implicitly create the author's identity" do
      author = User.new(name: "Not yet registered")
      message = @conversation.messages.new(sender: @desk, body: "On it!", author: author)
      assert_not message.valid?
      assert message.errors.of_kind?(:author, :invalid)
      assert_raises(ActiveRecord::RecordInvalid) do
        @desk.message!(@conversation, "On it!", author: author)
      end
      assert_not author.persisted?
    end

    test "an author who is not the sender does not have to be a participant" do
      # Lucía never joined the conversation — the DESK did. That's the whole
      # point of authorship: the seat is the member, the human is the writer.
      message = @desk.message!(@conversation, "On it!", author: @lucia)

      assert message.persisted?
      assert_not @conversation.participant?(@lucia)
    end
  end
end
