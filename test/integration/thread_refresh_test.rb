# frozen_string_literal: true

require "test_helper"

# The Campfire-pattern catch-up surfaces: the stale-thread refresh endpoint
# (GET /messages/:id/refresh?since=ms), the «new messages» divider on thread
# open, and the :conversation_read host notification that keeps external
# notification surfaces truthful.
class ThreadRefreshTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier

  setup do
    @alice = create_user(name: "Alice")
    @bob = create_user(name: "Bob")
    @conversation = conversation_between(@alice, @bob)
  end

  # --- the refresh endpoint -------------------------------------------------------

  test "refresh appends messages created since the cursor" do
    old_message = @bob.message!(@conversation, "before sleep")
    cursor = cursor_after(old_message)
    fresh = @bob.message!(@conversation, "while you slept")

    login_as @alice
    get "/messages/#{@conversation.id}/refresh", params: { since: cursor },
                                                 headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_includes response.body, %(action="append")
    assert_includes response.body, "while you slept"
    assert_not_includes response.body, "before sleep"
    assert_includes response.body, dom_id(fresh)
  end

  test "refresh replaces messages edited or tombstoned since the cursor" do
    message = @bob.message!(@conversation, "tpyo")
    cursor = cursor_after(message)
    message.edit!(body: "typo, fixed")

    login_as @alice
    get "/messages/#{@conversation.id}/refresh", params: { since: cursor },
                                                 headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_includes response.body, %(action="replace")
    assert_includes response.body, "typo, fixed"
  end

  test "refresh answers a deep backlog with a full page refresh instead of splicing" do
    anchor = @bob.message!(@conversation, "anchor")
    cursor = cursor_after(anchor)
    (Chats.config.messages_per_page + 1).times { |i| @bob.message!(@conversation, "burst #{i}") }

    login_as @alice
    get "/messages/#{@conversation.id}/refresh", params: { since: cursor },
                                                 headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_includes response.body, %(<turbo-stream action="refresh">)
    assert_not_includes response.body, "burst 0"
  end

  test "refresh without a cursor is a no-op, and outsiders get a 404" do
    login_as @alice
    get "/messages/#{@conversation.id}/refresh"
    assert_response :no_content

    carol = create_user(name: "Carol")
    login_as carol
    get "/messages/#{@conversation.id}/refresh", params: { since: 1 }
    assert_response :not_found
  end

  # --- the «new messages» divider ---------------------------------------------------

  test "opening a thread with unread messages renders the divider before the first unread" do
    @alice.message!(@conversation, "read long ago")
    @conversation.participant_for(@bob).read!
    first_unread = @alice.message!(@conversation, "you have not seen this")
    @alice.message!(@conversation, "nor this")

    login_as @bob
    get "/messages/#{@conversation.id}"

    assert_response :success
    assert_includes response.body, "chats-thread__unread-line"
    # The divider sits BEFORE the first unread bubble.
    divider_at = response.body.index("chats-thread__unread-line")
    first_unread_at = response.body.index(dom_id(first_unread))
    assert divider_at < first_unread_at, "divider should precede the first unread bubble"
  end

  test "a fully-read thread renders no divider" do
    @alice.message!(@conversation, "hi")
    @conversation.participant_for(@bob).read!

    login_as @bob
    get "/messages/#{@conversation.id}"

    assert_response :success
    assert_not_includes response.body, "chats-thread__unread-line"
  end

  # --- the :conversation_read host event ---------------------------------------------

  test "read! notifies the host once when unread content gets consumed, and not on no-ops" do
    events = []
    original = Chats.config.notifier
    Chats.config.notifier = ->(event, **payload) { events << [event, payload] }

    @alice.message!(@conversation, "ping")
    participant = @conversation.participant_for(@bob)

    participant.read!
    read_events = events.select { |event, _| event == :conversation_read }
    assert_equal 1, read_events.size
    assert_equal @conversation, read_events.first.last[:conversation]
    assert_equal participant, read_events.first.last[:participant]

    # Nothing newly unread → advancing the horizon again says nothing.
    participant.read!(at: 1.second.from_now)
    assert_equal(1, events.count { |event, _| event == :conversation_read })
  ensure
    Chats.config.notifier = original
  end

  private

  # The client cursor is the max data-updated-at-ms across rendered bubbles —
  # ceil'd past the sub-millisecond tail exactly like the partial emits it.
  def cursor_after(message)
    (message.reload.updated_at.to_f * 1000).ceil
  end
end
