# frozen_string_literal: true

require "test_helper"

module Chats
  class ReactionTest < ActiveSupport::TestCase
    setup do
      @alice = create_user(name: "Alice")
      @bob = create_user(name: "Bob")
      @conversation = conversation_between(@alice, @bob)
      @message = @conversation.messages.create!(sender: @alice, body: "react to me")
    end

    test "toggle! adds then removes" do
      reaction = Reaction.toggle!(message: @message, reactor: @bob, emoji: "👍")
      assert reaction.persisted?
      assert_equal 1, @message.reactions.count

      assert_equal false, Reaction.toggle!(message: @message, reactor: @bob, emoji: "👍")
      assert_equal 0, @message.reactions.count
    end

    test "same emoji from different reactors coexist; duplicates don't" do
      Reaction.toggle!(message: @message, reactor: @alice, emoji: "❤️")
      Reaction.toggle!(message: @message, reactor: @bob, emoji: "❤️")

      assert_equal 2, @message.reactions.count
      duplicate = Reaction.new(message: @message, reactor: @bob, emoji: "❤️")
      assert_not duplicate.valid?
    end

    test "only participants can react" do
      outsider = create_user

      assert_raises(ActiveRecord::RecordInvalid) do
        Reaction.toggle!(message: @message, reactor: outsider, emoji: "👍")
      end
    end

    test "respects the reactions feature flag" do
      Chats.config.reactions = false

      assert_raises(ActiveRecord::RecordInvalid) do
        Reaction.toggle!(message: @message, reactor: @bob, emoji: "👍")
      end
    end

    test "emoji must be short — no smuggled paragraphs" do
      reaction = Reaction.new(message: @message, reactor: @bob, emoji: "x" * 17)
      assert_not reaction.valid?
    end

    test "summary_for groups counts stably" do
      Reaction.toggle!(message: @message, reactor: @alice, emoji: "👍")
      Reaction.toggle!(message: @message, reactor: @bob, emoji: "👍")
      Reaction.toggle!(message: @message, reactor: @bob, emoji: "🚗")

      # Sorted by emoji codepoint (👍 U+1F44D < 🚗 U+1F697) so bubbles never
      # shuffle as counts change.
      assert_equal [["👍", 2], ["🚗", 1]], Reaction.summary_for(@message)
    end
  end
end
