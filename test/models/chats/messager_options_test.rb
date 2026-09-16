# frozen_string_literal: true

require "test_helper"

module Chats
  # `acts_as_messager notifications: false, blockable: false, inbox: :grouped`
  # — the headless messager. Everything a host used to express with
  # `is_a?(User)` checks in its notifiers and views.
  class MessagerOptionsTest < ActiveSupport::TestCase
    setup do
      @alice = create_user(name: "Alice")
      @desk = create_desk(name: "Support")
      @shop = create_shop(name: "Tienda Oficial")
    end

    test "a bare acts_as_messager keeps 0.1.x behaviour" do
      assert_equal Chats::Messager::DEFAULT_CHAT_OPTIONS, User.chat_options
      assert User.chat_notifications?
      assert User.chat_blockable?
      assert_equal :default, User.chat_inbox_mode
      assert_not User.chat_grouped_inbox?
      assert_nil User.chat_group_path
      assert_not User.chat_verified?, "nothing is an official account until it says so"
    end

    test "the headless declaration answers every predicate" do
      assert_not Desk.chat_notifications?
      assert_not Desk.chat_blockable?
      assert_equal :grouped, Desk.chat_inbox_mode
      assert Desk.chat_grouped_inbox?
      assert Desk.chat_verified?
      assert Desk.chat_options.frozen?
    end

    test "verified: is independent of the headless options" do
      # Shop is `acts_as_messager verified: true` and nothing else.
      assert Shop.chat_verified?
      assert Shop.chat_notifications?
      assert Shop.chat_blockable?
      assert_equal :default, Shop.chat_inbox_mode
    end

    test "the module-level readers are duck-typed, never class checks" do
      assert Chats.notifications_for?(@alice)
      assert_not Chats.notifications_for?(@desk)

      assert Chats.blockable?(@alice)
      assert_not Chats.blockable?(@desk)

      assert_not Chats.grouped_inbox?(@alice)
      assert Chats.grouped_inbox?(@desk)

      assert_not Chats.verified?(@alice)
      assert Chats.verified?(@desk)
      assert Chats.verified?(@shop)
      assert Chats.verified?(Shop), "the readers take a class as happily as a record"

      # A non-messager (or nil) is treated as a stock messager, never a crash.
      assert Chats.notifications_for?(nil)
      assert Chats.blockable?(create_listing)
      assert_not Chats.grouped_inbox?(nil)
      assert_not Chats.verified?(nil)
      assert_not Chats.verified?(create_listing)
    end

    test "a non-notifiable messager is never notifiable for a message" do
      conversation = @alice.chat_with(@desk)
      message = @alice.message!(conversation, "help!")

      desk_seat = conversation.participant_for(@desk)
      alice_seat = conversation.participant_for(@alice)

      assert_not desk_seat.notifiable_for?(message), "a headless desk must never be notified"
      # And the ordinary side still behaves exactly as before.
      assert alice_seat.notifiable_for?(@desk.message!(conversation, "on it!"))
    end

    test "bad options fail at boot with an actionable message" do
      error = assert_raises(Chats::ConfigurationError) do
        Class.new(ApplicationRecord) do
          def self.name = "BadInboxMessager"
          self.table_name = "users"
          acts_as_messager inbox: :piles
        end
      end
      assert_match(/inbox: must be one of \[:default, :grouped\]/, error.message)

      error = assert_raises(Chats::ConfigurationError) do
        Class.new(ApplicationRecord) do
          def self.name = "BadPathMessager"
          self.table_name = "users"
          acts_as_messager inbox: :grouped, group_path: "/support"
        end
      end
      assert_match(/group_path: must respond to #call/, error.message)

      # A badge is a trust claim: unlike its boolean neighbours, `verified:`
      # refuses to coerce, so a stray string can never verify an account.
      error = assert_raises(Chats::ConfigurationError) do
        Class.new(ApplicationRecord) do
          def self.name = "BadVerifiedMessager"
          self.table_name = "users"
          acts_as_messager verified: "false"
        end
      end
      assert_match(/verified: must be true or false, got "false"/, error.message)
    end

    test "options are inherited by STI subclasses" do
      subclass = Class.new(Desk) do
        def self.name = "PriorityDesk"
      end

      assert_not subclass.chat_notifications?
      assert subclass.chat_grouped_inbox?
      assert subclass.chat_verified?
    end

    test "a headless messager still converses like anyone else" do
      message = @alice.message!(@desk, "my payout is stuck")

      assert message.persisted?
      assert message.conversation.participant?(@desk)
      assert_includes @desk.chats, message.conversation
    end
  end
end
