# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < ActiveSupport::TestCase
  test "ships working defaults" do
    config = Chats::Configuration.new

    assert_equal "User", config.messager_class
    assert_equal "::ApplicationController", config.parent_controller
    assert_equal :current_user, config.current_messager_method
    assert_equal :authenticate_user!, config.authenticate_method
    assert_nil config.layout

    assert config.groups
    assert config.reactions
    assert config.read_receipts
    assert config.typing_indicators
    assert config.editing
    assert_equal :soft, config.deletion
    assert_equal :images, config.attachments
    assert config.search

    assert_equal 30, config.messages_per_page
    assert_equal 5_000, config.max_message_length
    assert_equal 32, config.max_group_size
    assert_equal({ to: 60, within: 60 }, config.send_rate_limit)
    refute config.encrypt_messages
  end

  test "configure yields, validates and returns the config" do
    result = Chats.configure { |config| config.messages_per_page = 10 }

    assert_equal 10, Chats.config.messages_per_page
    assert_same Chats.config, result
  end

  test "messager_class accepts classes and strings, rejects blanks" do
    Chats.config.messager_class = User
    assert_equal "User", Chats.config.messager_class

    Chats.config.messager_class = "Account"
    assert_equal "Account", Chats.config.messager_class

    assert_raises(Chats::ConfigurationError) { Chats.config.messager_class = "  " }
  end

  test "messager_model constantizes lazily" do
    Chats.config.messager_class = "User"
    assert_equal User, Chats.config.messager_model
  end

  test "attachments setter normalizes and validates modes" do
    Chats.config.attachments = "images"
    assert_equal :images, Chats.config.attachments

    Chats.config.attachments = false
    assert_equal false, Chats.config.attachments

    Chats.config.attachments = :any
    assert_equal :any, Chats.config.attachments

    assert_raises(Chats::ConfigurationError) { Chats.config.attachments = :videos }
  end

  test "deletion setter validates modes" do
    Chats.config.deletion = :hard
    assert_equal :hard, Chats.config.deletion

    Chats.config.deletion = false
    assert_equal false, Chats.config.deletion

    assert_raises(Chats::ConfigurationError) { Chats.config.deletion = :nuke }
  end

  test "send_rate_limit accepts nil and a {to:, within:} shape only" do
    Chats.config.send_rate_limit = nil
    assert_nil Chats.config.send_rate_limit

    Chats.config.send_rate_limit = { to: 5, within: 60 }
    assert_equal({ to: 5, within: 60 }, Chats.config.send_rate_limit)

    assert_raises(Chats::ConfigurationError) { Chats.config.send_rate_limit = { to: "lots" } }
  end

  test "hooks must be callable" do
    assert_raises(Chats::ConfigurationError) { Chats.config.notifier = :not_callable }
    assert_raises(Chats::ConfigurationError) { Chats.config.can_message = "nope" }
    assert_raises(Chats::ConfigurationError) { Chats.config.blocked_messager_ids = 42 }
  end

  test "validate! catches nonsense limits" do
    Chats.config.max_group_size = 2
    assert_raises(Chats::ConfigurationError) { Chats.config.validate! }

    Chats.reset!
    Chats.config.messages_per_page = 0
    assert_raises(Chats::ConfigurationError) { Chats.config.validate! }
  end

  test "reset! restores defaults and clears registries" do
    Chats.configure { |config| config.messages_per_page = 7 }
    Chats.reset!

    assert_equal 30, Chats.config.messages_per_page
  end

  test "messager and chat subject registries are ancestor-aware" do
    assert Chats.messager_class?(User)
    assert Chats.messager_class?("User")
    refute Chats.messager_class?(Listing)

    assert Chats.chat_subject_class?(Listing)
    refute Chats.chat_subject_class?(User)
  end

  test "blocked_between? consults the host proc bidirectionally" do
    alice = create_user
    bob = create_user
    carol = create_user

    refute Chats.blocked_between?(alice, bob)

    block_pair!(alice, bob)
    assert Chats.blocked_between?(alice, bob)
    assert Chats.blocked_between?(bob, alice)
    refute Chats.blocked_between?(alice, carol)
  end

  test "can_message? never bypasses blocks even with a permissive policy" do
    alice = create_user
    bob = create_user

    Chats.config.can_message = ->(_a, _b) { true }
    block_pair!(alice, bob)

    refute Chats.can_message?(alice, bob)
  end

  test "notify isolates notifier errors so message delivery never breaks" do
    Chats.config.notifier = ->(_event, **) { raise "boom" }

    assert_nothing_raised { Chats.notify(:message_created, message: nil) }
  end
end
