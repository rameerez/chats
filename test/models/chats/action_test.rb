# frozen_string_literal: true

require "test_helper"

module Chats
  # The value a message's button is made of: a label and a url, immutable,
  # compared by value, and strict about what it will be built from.
  class ActionTest < ActiveSupport::TestCase
    test "an action is a label and a url" do
      action = Chats::Action.new(label: "Join my room", url: "/play/friend/abcd")

      assert_equal "Join my room", action.label
      assert_equal "/play/friend/abcd", action.url
      assert_equal({ label: "Join my room", url: "/play/friend/abcd" }, action.to_h)
    end

    test "positional arguments work too, in member order" do
      assert_equal Chats::Action.new(label: "Pay now", url: "/pay"), Chats::Action.new("Pay now", "/pay")
    end

    test "it is immutable and compared by value" do
      action = Chats::Action.new(label: "Pay now", url: "/pay")

      assert_predicate action, :frozen?
      assert_not_respond_to action, :label=
      assert_equal action, Chats::Action.new(label: "Pay now", url: "/pay")
      assert_equal action.hash, Chats::Action.new(label: "Pay now", url: "/pay").hash
      assert_not_equal action, Chats::Action.new(label: "Pay later", url: "/pay")
    end

    test "its strings are frozen copies: neither the caller nor a reader can rewrite a validated action" do
      url = +"/pay"
      action = Chats::Action.new(label: +"Pay now", url: url)

      assert_predicate action.label, :frozen?
      assert_predicate action.url, :frozen?
      assert_raises(FrozenError) { action.url.replace("javascript:alert(1)") }
      assert_raises(FrozenError) { action.label << "!" }

      url.replace("javascript:alert(1)")
      assert_equal "/pay", action.url, "mutating the string the caller passed must not reach the action"
    end

    test "both members are required" do
      assert_raises(ArgumentError) { Chats::Action.new(label: "Pay now") }
      assert_raises(ArgumentError) { Chats::Action.new(url: "/pay") }
    end

    test "members become the text the column will hold, and nil stays nil" do
      action = Chats::Action.new(label: :pay, url: URI("https://pay.example/invoices/1"))

      assert_equal "pay", action.label
      assert_equal "https://pay.example/invoices/1", action.url
      assert_nil Chats::Action.new(label: nil, url: nil).label, "a missing label must stay missing, not become ''"
    end

    # --- wrap ---------------------------------------------------------------------

    test "wrap leaves nil as nil and an action as itself" do
      action = Chats::Action.new(label: "Pay now", url: "/pay")

      assert_nil Chats::Action.wrap(nil)
      assert_same action, Chats::Action.wrap(action)
    end

    test "wrap builds an action from a hash with symbol or string keys" do
      expected = Chats::Action.new(label: "Book another", url: "/rides/new")

      assert_equal expected, Chats::Action.wrap({ label: "Book another", url: "/rides/new" })
      assert_equal expected, Chats::Action.wrap({ "label" => "Book another", "url" => "/rides/new" })
      assert_equal expected, Chats::Action.wrap({ "label" => "Book another", url: "/rides/new" })
      indifferent = ActiveSupport::HashWithIndifferentAccess.new(label: "Book another", url: "/rides/new")
      assert_equal expected, Chats::Action.wrap(indifferent)
    end

    test "wrap leaves a missing key to the message's validation" do
      action = Chats::Action.wrap({ label: "Pay now" })

      assert_equal "Pay now", action.label
      assert_nil action.url
    end

    test "wrap refuses keys an action doesn't have, instead of dropping them" do
      error = assert_raises(ArgumentError) do
        Chats::Action.wrap({ label: "Pay now", url: "/pay", method: :post })
      end

      assert_includes error.message, "method"
    end

    test "wrap refuses anything that isn't nil, a hash or an action" do
      ["/pay", "", :pay, 42, [%w[label Pay], %w[url /pay]], Object.new].each do |value|
        assert_raises(ArgumentError, "#{value.inspect} must not become an action") { Chats::Action.wrap(value) }
      end
    end

    # --- the column type ------------------------------------------------------------

    test "the column type stores label and url as JSON and reads an action back" do
      type = Chats::Action::Type.new
      action = Chats::Action.new(label: "Pay now", url: "/pay")

      stored = type.serialize(action)
      assert_equal({ "label" => "Pay now", "url" => "/pay" }, JSON.parse(stored))
      assert_equal action, type.deserialize(stored)
      assert_nil type.serialize(nil)
      assert_nil type.deserialize(nil)
    end

    test "the column type ignores keys a later version might add, rather than failing to load the row" do
      type = Chats::Action::Type.new

      assert_equal Chats::Action.new(label: "Pay now", url: "/pay"),
                   type.deserialize({ label: "Pay now", url: "/pay", style: "primary" }.to_json)
    end

    test "the column type reads a stored non-object as no action" do
      assert_nil Chats::Action::Type.new.deserialize("null")
      assert_nil Chats::Action::Type.new.deserialize("[1,2]")
    end
  end
end
