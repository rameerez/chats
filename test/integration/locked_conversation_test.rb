# frozen_string_literal: true

require "test_helper"

# A locked subject closes its conversation for WRITING only. The screen says
# why, in place: gate the action, never hide the explanation.
class LockedConversationTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier

  SLOT_VIEWS = File.expand_path("../fixtures/slot_views", __dir__)

  setup do
    @alice = create_user(name: "Alice")
    @bob = create_user(name: "Bob")
    @listing = create_listing(title: "Madrid → Barcelona")
    @conversation = @alice.chat_with(@bob, about: @listing)
    login_as @alice
  end

  test "an open conversation renders the composer" do
    get "/messages/#{@conversation.id}"

    assert_response :success
    assert_equal 1, css_select("form.chats-composer").size
    assert_empty css_select(".chats-composer--locked")
  end

  test "a locked conversation swaps the composer for the subject's notice" do
    @alice.message!(@conversation, "said before the lock")
    @listing.update!(locked: true)

    get "/messages/#{@conversation.id}"

    assert_response :success
    assert_empty css_select("form.chats-composer"), "no composer where sending would fail"
    assert_equal "This listing is closed.", css_select(".chats-composer__locked-notice").first.text
    assert_includes response.body, "said before the lock", "history stays readable"
  end

  test "the locked composer keeps the composer's DOM id so a live lock can swap it" do
    @listing.update!(locked: true)

    get "/messages/#{@conversation.id}"

    assert_equal 1, css_select("##{dom_id(@conversation, :composer)}").size
  end

  test "sending into a locked conversation is a 422 that replaces the composer" do
    @listing.update!(locked: true)

    post "/messages/#{@conversation.id}/messages",
         params: { message: { body: "sneaking one in" } },
         as: :turbo_stream

    assert_response :unprocessable_entity
    assert_includes response.body, %(action="replace")
    assert_includes response.body, dom_id(@conversation, :composer)
    assert_includes response.body, "This listing is closed."
    assert_equal 0, @conversation.messages.count
  end

  test "the no-JS path redirects with the notice instead of raising" do
    @listing.update!(locked: true)

    post "/messages/#{@conversation.id}/messages", params: { message: { body: "sneaking one in" } }

    assert_redirected_to "/messages/#{@conversation.id}"
    assert_equal "This listing is closed.", flash[:alert]
  end

  test "an ordinary validation failure still lands in the composer's error slot" do
    post "/messages/#{@conversation.id}/messages",
         params: { message: { body: "" } },
         as: :turbo_stream

    assert_response :unprocessable_entity
    assert_includes response.body, dom_id(@conversation, :composer_errors)
    assert_not_includes response.body, "This listing is closed."
  end

  # --- every write endpoint, not just create --------------------------------

  test "editing a message in a locked conversation is refused, body untouched" do
    said = @alice.message!(@conversation, "before the lock")
    @listing.update!(locked: true)

    patch "/messages/#{@conversation.id}/messages/#{said.id}",
          params: { message: { body: "sneaking an edit in" } },
          as: :turbo_stream

    assert_response :unprocessable_entity
    assert_includes response.body, "This listing is closed."
    assert_equal "before the lock", said.reload.body
    assert_nil said.edited_at
  end

  test "deleting a message in a locked conversation is refused, no tombstone" do
    said = @alice.message!(@conversation, "before the lock")
    @listing.update!(locked: true)

    delete "/messages/#{@conversation.id}/messages/#{said.id}", as: :turbo_stream

    assert_response :unprocessable_entity
    assert_includes response.body, "This listing is closed."
    assert_not said.reload.deleted?
  end

  test "reacting in a locked conversation is refused" do
    said = @alice.message!(@conversation, "before the lock")
    @listing.update!(locked: true)

    post "/messages/#{@conversation.id}/messages/#{said.id}/reactions",
         params: { emoji: "👍" },
         as: :turbo_stream

    assert_response :unprocessable_entity
    assert_includes response.body, "This listing is closed."
    assert_equal 0, Chats::Reaction.count
  end

  test "the no-JS write paths redirect with the notice instead of raising" do
    said = @alice.message!(@conversation, "before the lock")
    @listing.update!(locked: true)

    delete "/messages/#{@conversation.id}/messages/#{said.id}"

    assert_redirected_to "/messages/#{@conversation.id}"
    assert_equal "This listing is closed.", flash[:alert]
  end

  test "a locked thread stops offering edit, delete and reactions" do
    said = @alice.message!(@conversation, "before the lock")
    Chats::Reaction.toggle!(message: said, reactor: @bob, emoji: "👍")

    get "/messages/#{@conversation.id}"
    assert_includes response.body, "data-chats-action=\"edit\""
    assert_equal 1, css_select("form.button_to .chats-reaction").size

    @listing.update!(locked: true)
    get "/messages/#{@conversation.id}"

    assert_response :success
    assert_not_includes response.body, "data-chats-action=\"edit\""
    assert_not_includes response.body, I18n.t("chats.message.delete_confirm")
    assert_empty css_select("form.button_to .chats-reaction"), "no toggle buttons in a closed thread"
    assert_equal 1, css_select(".chats-reaction--locked").size, "existing reactions still show, as plain counts"
    assert_includes response.body, I18n.t("chats.message.copy"), "copying is not a write"
  end

  test "the locked_composer slot replaces the body and keeps the id contract" do
    @listing.update!(locked: true)

    with_slot_views do
      get "/messages/#{@conversation.id}"
    end

    assert_response :success
    assert_equal 1, css_select("##{dom_id(@conversation, :composer)}").size
    assert_empty css_select(".chats-composer__locked-notice"), "the slot replaces the default body"
    assert_includes css_select(".dummy-locked-body").first.text, "This listing is closed. Reopen it"
  end

  private

  # Prepend a view path carrying `chats/slots/_locked_composer` — the way an
  # engine mounted on top of chats (support_desk) ships its own slot.
  def with_slot_views
    original = Chats::ApplicationController.view_paths
    Chats::ApplicationController.prepend_view_path(SLOT_VIEWS)
    yield
  ensure
    Chats::ApplicationController.view_paths = original
  end
end
