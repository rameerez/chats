# frozen_string_literal: true

require "test_helper"

module Chats
  # A message may carry ONE featured button. The host sets it from Ruby; the
  # message decides whether it is safe to render, keeps it through an edit,
  # and drops it with the words when the message becomes a tombstone.
  class MessageActionTest < ActiveSupport::TestCase
    setup do
      @alice = create_user(name: "Alice")
      @bob = create_user(name: "Bob")
      @conversation = conversation_between(@alice, @bob)
    end

    # --- the two call sites -----------------------------------------------------

    test "messages carry no action by default" do
      message = @alice.message!(@bob, "hola!")

      assert_nil message.action
      assert_not message.action?
    end

    test "message! takes an action" do
      message = @alice.message!(@bob, "Let's play!", action: { label: "Join my room", url: "/play/friend/abcd" })

      assert message.action?
      assert_equal Chats::Action.new(label: "Join my room", url: "/play/friend/abcd"), message.reload.action
    end

    test "message! takes an action alongside an author and an about" do
      lucia = create_user(name: "Lucía")
      desk = create_desk(name: "Support")
      listing = create_listing

      message = desk.message!(@alice, "Your invoice is ready",
                              author: lucia, about: listing,
                              action: { label: "Pay now", url: "https://pay.example/1" })

      assert_equal lucia, message.author
      assert_equal listing, message.conversation.subject
      assert_equal "https://pay.example/1", message.reload.action.url
    end

    test "post_system_message! takes an action" do
      message = @conversation.post_system_message!("Your ride was cancelled",
                                                   action: { label: "Book another", url: "/rides/new" })

      assert message.system?
      assert_equal Chats::Action.new(label: "Book another", url: "/rides/new"), message.reload.action
    end

    test "post_system_message! without an action is unchanged" do
      assert_nil @conversation.post_system_message!("Ride cancelled").action
    end

    test "an invalid action refuses the whole send, from either call site" do
      assert_no_difference "Chats::Message.count" do
        assert_raises(ActiveRecord::RecordInvalid) do
          @alice.message!(@bob, "click me", action: { label: "Win", url: "javascript:alert(1)" })
        end
        assert_raises(ActiveRecord::RecordInvalid) do
          @conversation.post_system_message!("click me", action: { label: "Win", url: "//evil.example" })
        end
      end
    end

    test "an action never replaces the words" do
      assert_raises(ActiveRecord::RecordInvalid) do
        @alice.message!(@bob, nil, action: { label: "Join my room", url: "/play" })
      end
      assert_raises(ActiveRecord::RecordInvalid) do
        @conversation.post_system_message!(nil, action: { label: "Book another", url: "/rides/new" })
      end
    end

    # --- what can be assigned ---------------------------------------------------

    test "a hash, an action and nil can all be assigned, and reads are always an action or nil" do
      message = @conversation.messages.new(sender: @alice, body: "hi")

      message.action = { "label" => "Pay now", "url" => "/pay" }
      assert_equal Chats::Action.new(label: "Pay now", url: "/pay"), message.action

      message.action = Chats::Action.new(label: "Pay later", url: "/pay/later")
      assert_equal "Pay later", message.action.label

      message.action = nil
      assert_nil message.action
      assert_not message.action?
    end

    test "assigning anything else raises where it was assigned" do
      message = @conversation.messages.new(sender: @alice, body: "hi")

      assert_raises(ArgumentError) { message.action = "/pay" }
      assert_raises(ArgumentError) { message.action = { label: "Pay", url: "/pay", method: :post } }
    end

    test "the column holds exactly a label and a url" do
      message = @alice.message!(@bob, "Your invoice is ready", action: { label: "Pay now", url: "/pay" })

      raw = Chats::Message.connection.select_value(
        Chats::Message.where(id: message.id).select(:action).to_sql
      )
      assert_equal({ "label" => "Pay now", "url" => "/pay" }, raw.is_a?(String) ? JSON.parse(raw) : raw)
    end

    test "an action is its own column: metadata stays the host's" do
      message = @alice.message!(@bob, "Your invoice is ready", action: { label: "Pay now", url: "/pay" })

      assert_equal({}, message.reload.metadata)
    end

    test "dirty tracking sees a new action and ignores an identical one" do
      message = @alice.message!(@bob, "hi", action: { label: "Pay now", url: "/pay" })
      message.reload

      message.action = { label: "Pay now", url: "/pay" }
      assert_not message.action_changed?, "the same label and url is the same action"

      message.action = { label: "Pay now", url: "/pay/2" }
      assert message.action_changed?
    end

    # --- validation -------------------------------------------------------------

    test "accepts a site-relative path and an absolute http(s) url" do
      [
        "/play/friend/abcd",
        "/rides/new?from=chat#top",
        "/",
        "https://pay.example/invoices/1",
        "http://pay.example",
        "HTTPS://pay.example/upper",
        "https://pay.example:8443/port"
      ].each do |url|
        assert_predicate action_message(url: url), :valid?, "#{url.inspect} should be a fine destination"
      end
    end

    test "refuses every url that isn't http(s) or a path on this site" do
      {
        "javascript:alert(1)" => "javascript",
        "JavaScript:alert(1)" => "javascript, any case",
        "data:text/html,<script>alert(1)</script>" => "data",
        "vbscript:msgbox(1)" => "vbscript",
        "mailto:hello@example.com" => "mailto",
        "ftp://files.example/report" => "ftp",
        "//evil.example/phish" => "protocol-relative",
        "/\\evil.example" => "a backslash browsers turn into //",
        "/\t/evil.example" => "a tab browsers strip into //",
        "/\n/evil.example" => "a newline browsers strip into //",
        " /play" => "leading whitespace",
        "http://" => "a scheme with no host",
        "https:/evil.example" => "a scheme with no authority",
        "https:evil.example" => "an opaque https",
        "play/friend" => "a relative path",
        "?tab=games" => "a bare query",
        "#games" => "a bare fragment",
        "" => "empty",
        "   " => "blank"
      }.each do |url, why|
        message = action_message(url: url)

        assert_not message.valid?, "#{url.inspect} (#{why}) must be refused"
        assert message.errors.of_kind?(:action, :invalid)
      end
    end

    test "a site path never starts with a second slash or a backslash, however many follow" do
      # URI.parse sees no host in "///evil.example", but a browser resolves
      # it to https://evil.example — so these are refused before parsing.
      ["//", "///", "///evil.example/path", "////evil", "/\\evil", "/\\\\evil", "/\\/evil"].each do |url|
        message = action_message(url: url)

        assert_not message.valid?, "#{url.inspect} must be refused: a browser may leave the site"
        assert message.errors.of_kind?(:action, :invalid)
      end

      assert_predicate action_message(url: "/ok"), :valid?
      assert_predicate action_message(url: "/ok//double/inside"), :valid?, "only the start decides"
    end

    test "an absolute url's port must be a real port" do
      assert_predicate action_message(url: "https://pay.example:1/x"), :valid?
      assert_predicate action_message(url: "https://pay.example:65535/x"), :valid?

      %w[https://pay.example:0/x https://pay.example:65536/x https://pay.example:99999/x].each do |url|
        assert_not action_message(url: url).valid?, "#{url} has no such port"
      end
    end

    test "an empty port suffix is refused, not read as the default port" do
      %w[https://pay.example:/x https://pay.example: https://pay.example:?q=1 HTTPS://pay.example:#top].each do |url|
        assert_not action_message(url: url).valid?, "#{url} names no port"
      end
      assert_predicate action_message(url: "https://pay.example/x:y"), :valid?, "a colon in the path is not a port"
    end

    test "the url has a length limit" do
      path = "/#{"a" * (Chats::Message::ACTION_URL_LIMIT - 1)}"

      assert_predicate action_message(url: path), :valid?
      assert_not action_message(url: "#{path}a").valid?
    end

    test "the label must be present and short enough to be a button" do
      assert_predicate action_message(label: "a" * Chats::Message::ACTION_LABEL_LIMIT), :valid?

      [nil, "", "   ", "a" * (Chats::Message::ACTION_LABEL_LIMIT + 1)].each do |label|
        message = action_message(label: label)

        assert_not message.valid?, "#{label.inspect} must be refused as a label"
        assert message.errors.of_kind?(:action, :invalid)
      end
    end

    test "a missing url is refused" do
      message = @conversation.messages.new(sender: @alice, body: "hi", action: { label: "Pay now" })

      assert_not message.valid?
      assert message.errors.of_kind?(:action, :invalid)
    end

    test "the error explains itself, in English and in Spanish" do
      message = action_message(url: "javascript:alert(1)")
      message.validate

      assert_equal "Action needs a label of up to 80 characters and a link to an http(s) address " \
                   "or to a path on this site that starts with /",
                   message.errors.full_messages_for(:action).first

      I18n.with_locale(:es) do
        message.validate
        assert_equal "Acción necesita un texto de hasta 80 caracteres y un enlace a una dirección http(s) " \
                     "o a una ruta de este sitio que empiece por /",
                     message.errors.full_messages_for(:action).first
      end
    end

    # --- through the message's life ---------------------------------------------

    test "editing keeps the action" do
      message = @alice.message!(@bob, "Let's play!", action: { label: "Join my room", url: "/play" })

      message.edit!("Let's play tonight!")

      assert_equal "Join my room", message.reload.action.label
    end

    test "an edit never fails over an action nobody touched" do
      message = @alice.message!(@bob, "Let's play!", action: { label: "Join my room", url: "/play" })
      # A stored action today's rules would refuse (rules may tighten in a
      # later version; the row was valid when it was written).
      message.update_column(:action, { label: "Join my room", url: "ftp://legacy.example" })

      assert message.reload.edit!("still editable")
    end

    test "the tombstone shows neither the words nor the button" do
      message = @alice.message!(@bob, "Your invoice is ready", action: { label: "Pay now", url: "/pay" })

      assert message.soft_delete!

      message.reload
      assert message.deleted?
      assert_nil message.body
      assert_nil message.action
      assert_not message.action?
    end

    test "a moderator's removal takes the button down with the body" do
      message = @alice.message!(@bob, "free money", action: { label: "Claim it", url: "https://scam.example" })

      assert message.remove_reported_field!(:body)

      assert_nil message.reload.action
    end

    test "a moderator's removal clears the action even in a locked conversation" do
      listing = create_listing
      conversation = @alice.chat_with(@bob, about: listing)
      message = @alice.message!(conversation, "free money", action: { label: "Claim it", url: "https://scam.example" })
      listing.update!(locked: true)

      assert message.remove_reported_field!(:body)

      assert_nil message.reload.action
    end

    test "hard deletion takes the row, action and all" do
      Chats.config.deletion = :hard
      message = @alice.message!(@bob, "Your invoice is ready", action: { label: "Pay now", url: "/pay" })

      assert message.soft_delete!
      assert_not Chats::Message.exists?(message.id)
    end

    private

    def action_message(label: "Join my room", url: "/play/friend/abcd")
      @conversation.messages.new(sender: @alice, body: "Let's play!", action: { label: label, url: url })
    end
  end
end
