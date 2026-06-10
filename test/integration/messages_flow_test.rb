# frozen_string_literal: true

require "test_helper"

class MessagesFlowTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier

  setup do
    @alice = create_user(name: "Alice")
    @bob = create_user(name: "Bob")
    @conversation = conversation_between(@alice, @bob)
  end

  # --- sending --------------------------------------------------------------------

  test "sending responds with a turbo_stream append for the sender" do
    login_as @alice

    assert_difference "Chats::Message.count", 1 do
      post "/messages/#{@conversation.id}/messages",
           params: { message: { body: "instant!" } },
           as: :turbo_stream
    end

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_includes response.body, %(action="append")
    assert_includes response.body, dom_id(@conversation, :messages)
    assert_includes response.body, "instant!"
    assert_includes response.body, "data-chats-message-receipt"
    assert_includes response.body, "data-chats-message-receipt-label"
    assert_includes response.body, "hidden"
    assert_not_includes response.body, "aria-label=\"Sent\""
    assert_not_includes response.body, "✓"
  end

  test "sending falls back to a redirect without turbo" do
    login_as @alice

    post "/messages/#{@conversation.id}/messages", params: { message: { body: "plain" } }
    assert_redirected_to "/messages/#{@conversation.id}"
  end

  test "invalid messages return 422 with the error rendered" do
    login_as @alice

    assert_no_difference "Chats::Message.count" do
      post "/messages/#{@conversation.id}/messages",
           params: { message: { body: "" } },
           as: :turbo_stream
    end

    assert_response :unprocessable_entity
    assert_includes response.body, dom_id(@conversation, :composer_errors)
  end

  test "outsiders can't send — 404" do
    outsider = create_user
    login_as outsider

    post "/messages/#{@conversation.id}/messages", params: { message: { body: "let me in" } }
    assert_response :not_found
  end

  test "a block placed mid-conversation turns sends into 404s" do
    login_as @alice
    post "/messages/#{@conversation.id}/messages", params: { message: { body: "pre-block" } }
    assert_response :redirect

    block_pair!(@alice, @bob)
    post "/messages/#{@conversation.id}/messages", params: { message: { body: "post-block" } }
    assert_response :not_found # the thread itself is hidden once blocked
  end

  test "sending with an image attachment" do
    login_as @alice

    post "/messages/#{@conversation.id}/messages",
         params: { message: { body: "with pic", files: [png_upload] } },
         as: :turbo_stream

    assert_response :success
    message = Chats::Message.order(:created_at).last
    assert message.attachments?
    assert_equal "photo.png", message.files.first.filename.to_s
  end

  test "non-image attachments are rejected in :images mode" do
    login_as @alice

    post "/messages/#{@conversation.id}/messages",
         params: { message: { body: "with txt", files: [text_upload] } },
         as: :turbo_stream

    assert_response :unprocessable_entity
  end

  # --- editing ----------------------------------------------------------------------

  test "the author edits through the composer (PATCH from the long-press flow)" do
    message = @alice.message!(@conversation, "typoo")
    login_as @alice

    # The composer form, re-targeted by the long-press Edit action, PATCHes
    # the same message[body] param it POSTs — no separate edit form exists.
    patch "/messages/#{@conversation.id}/messages/#{message.id}",
          params: { message: { body: "fixed" } },
          as: :turbo_stream
    assert_response :success
    assert_includes response.body, %(action="replace")
    assert_equal "fixed", message.reload.body
    assert message.edited?
  end

  test "only the author can edit or delete" do
    message = @alice.message!(@conversation, "mine")
    login_as @bob

    patch "/messages/#{@conversation.id}/messages/#{message.id}", params: { message: { body: "hijack" } }
    assert_response :not_found

    delete "/messages/#{@conversation.id}/messages/#{message.id}"
    assert_response :not_found
    assert_equal "mine", message.reload.body
  end

  test "invalid edits land in the composer's error slot" do
    message = @alice.message!(@conversation, "valid")
    login_as @alice

    patch "/messages/#{@conversation.id}/messages/#{message.id}",
          params: { message: { body: "" } },
          as: :turbo_stream

    assert_response :unprocessable_entity
    assert_includes response.body, "composer_errors"
    assert_equal "valid", message.reload.body
  end

  test "bubbles carry the long-press menu template instead of inline actions" do
    message = @alice.message!(@conversation, "press me")
    login_as @alice

    get "/messages/#{@conversation.id}"
    assert_response :success

    # Everything actionable is inert template content for the popup…
    assert_select "##{ActionView::RecordIdentifier.dom_id(message)} template[data-chats-message-menu]" do
      assert_select ".chats-popup__reactions form", 6
      assert_select "[data-chats-action='copy']"
      assert_select "[data-chats-action='edit'][data-chats-own-only]"
      assert_select "form[data-chats-own-only] .chats-popup__item--danger"
    end
    # …and the popup overlay + composer edit cue are mounted once per thread.
    assert_select "[data-chats--thread-target='popup'] .chats-popup__backdrop"
    assert_select "[data-chats--composer-target='editBar'][hidden]"
    # The old always-visible affordances are gone.
    assert_select ".chats-message__actions", 0
  end

  test "show returns the bubble (the cancel-edit path)" do
    message = @alice.message!(@conversation, "bubble")
    login_as @alice

    get "/messages/#{@conversation.id}/messages/#{message.id}", as: :turbo_stream
    assert_response :success
    assert_includes response.body, %(action="replace")
    assert_includes response.body, "bubble"
  end

  # --- deleting ----------------------------------------------------------------------

  test "the author soft-deletes to a tombstone" do
    message = @alice.message!(@conversation, "regret")
    login_as @alice

    delete "/messages/#{@conversation.id}/messages/#{message.id}", as: :turbo_stream
    assert_response :success
    assert_includes response.body, "chats-message--deleted"
    assert message.reload.deleted?
    assert_nil message.body
  end

  test "hard deletion removes the bubble outright" do
    Chats.config.deletion = :hard
    message = @alice.message!(@conversation, "vanish")
    login_as @alice

    delete "/messages/#{@conversation.id}/messages/#{message.id}", as: :turbo_stream
    assert_response :success
    assert_includes response.body, %(action="remove")
    assert_not Chats::Message.exists?(message.id)
  end

  # --- reactions ----------------------------------------------------------------------

  test "reactions toggle through the endpoint" do
    message = @alice.message!(@conversation, "react!")
    login_as @bob

    post "/messages/#{@conversation.id}/messages/#{message.id}/reactions",
         params: { emoji: "👍" },
         as: :turbo_stream
    assert_response :success
    assert_equal 1, message.reactions.count
    assert_includes response.body, "👍"

    post "/messages/#{@conversation.id}/messages/#{message.id}/reactions",
         params: { emoji: "👍" },
         as: :turbo_stream
    assert_equal 0, message.reactions.count
  end

  test "reactions respect the feature flag" do
    Chats.config.reactions = false
    message = @alice.message!(@conversation, "no reactions")
    login_as @bob

    post "/messages/#{@conversation.id}/messages/#{message.id}/reactions",
         params: { emoji: "👍" },
         as: :turbo_stream
    assert_response :unprocessable_entity
  end

  test "read receipt markup is omitted when receipts are disabled" do
    Chats.config.read_receipts = false
    login_as @alice

    post "/messages/#{@conversation.id}/messages",
         params: { message: { body: "private delivery state" } },
         as: :turbo_stream

    assert_response :success
    assert_not_includes response.body, "data-chats-message-receipt"
  end
end
