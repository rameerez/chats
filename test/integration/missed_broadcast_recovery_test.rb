# frozen_string_literal: true

require "test_helper"

# What each live surface fetches when its stream may have missed a
# broadcast (chats/recovery decides when; test/javascript), through the
# full request cycle: the badge endpoint, the thread's catch-up, and the
# markup the catch-up controllers hang on.
class MissedBroadcastRecoveryTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier

  TURBO_STREAM = "text/vnd.turbo-stream.html"

  setup do
    @alice = create_user(name: "Alice")
    @bob = create_user(name: "Bob")
    @conversation = conversation_between(@alice, @bob)
  end

  # --- GET /badge -------------------------------------------------------------

  test "the badge endpoint replaces every unread badge on the page with the viewer's unread_chats_count" do
    other = conversation_between(@alice, create_user(name: "Carol"))
    @bob.message!(@conversation, "one")
    @bob.message!(@conversation, "two, same conversation")
    other.messages.create!(sender: other.participants.where.not(messager: @alice).first.messager, body: "three")
    assert_equal 2, @alice.unread_chats_count

    login_as @alice
    get "/messages/badge", headers: { "Accept" => TURBO_STREAM }

    assert_response :success
    assert_equal TURBO_STREAM, response.media_type
    streams = css_select("turbo-stream")
    assert_equal [%w[replace chats_unread_badge], ["replace", nil]], actions_and_targets(streams)
    assert_equal ".chats-dock [data-chats-unread-badge]", streams.last["targets"]

    nav = css_select(streams.first, "#chats_unread_badge").sole
    assert_equal "2", nav.text.strip
    assert_nil nav["hidden"]
    dock = css_select(streams.last, "[data-chats-unread-badge]").sole
    assert_equal "2", dock["data-count"]
  end

  test "the badge endpoint counts what the inbox shows, says zero by hiding the badge, and reads nothing" do
    hidden = conversation_between(@alice, @bob, about: create_listing(title: "Hidden"))
    @bob.message!(hidden, "out of scope")
    Chats.config.inbox_scope = ->(relation, _viewer) { relation.where(subject_id: nil) }

    login_as @alice
    get "/messages/badge", headers: { "Accept" => TURBO_STREAM }

    assert_response :success
    nav = css_select("turbo-stream[target='chats_unread_badge'] #chats_unread_badge").sole
    assert nav.key?("hidden"), "nothing unread that the inbox shows: the badge hides"
    assert hidden.participant_for(@alice).reload.unread?, "asking for the badge is not reading"
  end

  test "the badge endpoint is the viewer's own: signed out, there is nothing to count" do
    get "/messages/badge", headers: { "Accept" => TURBO_STREAM }
    assert_response :unauthorized
  end

  test "the badge endpoint is a collection route, never read as a conversation id" do
    assert_equal({ controller: "chats/conversations", action: "badge" },
                 Chats::Engine.routes.recognize_path("/badge", method: :get).slice(:controller, :action))
  end

  # --- the thread's catch-up ---------------------------------------------------------

  test "a stale cursor returns exactly the messages it missed, the ones changed since, and the read state" do
    seen = @bob.message!(@conversation, "seen before the drop")
    edited = @bob.message!(@conversation, "tpyo")
    cursor = cursor_after(edited)
    travel 1.second
    missed = [@bob.message!(@conversation, "missed one"), @alice.message!(@conversation, "missed two")]
    edited.edit!("typo, fixed")
    @conversation.participant_for(@bob).read!

    login_as @alice
    get "/messages/#{@conversation.id}/refresh", params: cursor, headers: { "Accept" => TURBO_STREAM }

    assert_response :success
    append = css_select("turbo-stream[action='append']").sole
    assert_equal dom_id(@conversation, :messages), append["target"]
    assert_equal(missed.map { |message| dom_id(message) },
                 appended_ids(append))

    replaced = css_select("turbo-stream[action='replace']").map { |stream| stream["target"] }
    assert_equal [dom_id(edited), dom_id(@conversation, :read_state)], replaced
    assert_includes response.body, "typo, fixed"
    assert_not_includes response.body, dom_id(seen)
    assert_includes css_select("turbo-stream[target='#{dom_id(@conversation, :read_state)}']").to_html,
                    Chats.messager_key(@bob), "who has read what, as the read-state broadcast says it"
  end

  test "a message created before a rendered bubble's latest edit, and missed, still comes" do
    # 10:00 rendered; 10:15 created and missed; 10:20 the rendered one is
    # edited and the edit arrives live. The newest change is 10:20, the
    # missed message older than it: one cursor would lose it for good.
    shown = travel_to(Time.zone.parse("2026-10-18 10:00")) { @bob.message!(@conversation, "shown") }
    rendered = cursor_after(shown)
    missed = travel_to(Time.zone.parse("2026-10-18 10:15")) { @bob.message!(@conversation, "missed at 10:15") }
    travel_to(Time.zone.parse("2026-10-18 10:20")) { shown.edit!("shown, edited at 10:20") }
    cursors = rendered.merge(since: cursor_after(shown)[:since]) # the edit came in live

    login_as @alice
    get "/messages/#{@conversation.id}/refresh", params: cursors, headers: { "Accept" => TURBO_STREAM }

    append = css_select("turbo-stream[action='append']").sole
    assert_equal [dom_id(missed)], appended_ids(append)
    assert_empty css_select("turbo-stream[action='replace'][target='#{dom_id(shown)}']"),
                 "the edit it already has isn't sent again"
  end

  test "a change to a rendered bubble since the newest change comes as a replacement, never as an append" do
    shown = @bob.message!(@conversation, "shown")
    cursors = cursor_after(shown)
    travel 1.second
    shown.edit!("changed while away")

    login_as @alice
    get "/messages/#{@conversation.id}/refresh", params: cursors, headers: { "Accept" => TURBO_STREAM }

    assert_empty css_select("turbo-stream[action='append']")
    assert css_select("turbo-stream[action='replace'][target='#{dom_id(shown)}']").one?
  end

  test "an empty thread asks from the epoch, and its first message, missed, comes" do
    first = @bob.message!(@conversation, "the very first, while the cable was down")

    login_as @alice
    get "/messages/#{@conversation.id}/refresh", params: { since: 0, after: 0 }, headers: { "Accept" => TURBO_STREAM }

    append = css_select("turbo-stream[action='append']").sole
    assert_equal [dom_id(first)], appended_ids(append)
  end

  test "a reaction made while the client wasn't listening is caught up" do
    message = @alice.message!(@conversation, "react to me")
    cursor = cursor_after(message)
    travel 1.second
    Chats::Reaction.toggle!(message: message, reactor: @bob, emoji: "🎉")

    login_as @alice
    get "/messages/#{@conversation.id}/refresh", params: cursor, headers: { "Accept" => TURBO_STREAM }

    replace = css_select("turbo-stream[action='replace'][target='#{dom_id(message)}']").sole
    assert_includes replace.to_html, "🎉"
  end

  test "an up-to-date client gets the read state and nothing else" do
    message = @bob.message!(@conversation, "all caught up")

    login_as @alice
    get "/messages/#{@conversation.id}/refresh", params: cursor_after(message),
                                                 headers: { "Accept" => TURBO_STREAM }

    assert_equal [["replace", dom_id(@conversation, :read_state)]], actions_and_targets(css_select("turbo-stream"))
  end

  test "catching up reads nothing" do
    anchor = @alice.message!(@conversation, "anchor")
    cursor = cursor_after(anchor)
    @bob.message!(@conversation, "unread while away")

    login_as @alice
    get "/messages/#{@conversation.id}/refresh", params: cursor, headers: { "Accept" => TURBO_STREAM }

    assert_response :success
    assert @conversation.participant_for(@alice).reload.unread?
  end

  test "under deletion: :hard, the catch-up names every message from the oldest bubble on that still exists" do
    Chats.config.deletion = :hard
    before_window = @bob.message!(@conversation, "older than anything rendered")
    travel 1.second
    oldest = @bob.message!(@conversation, "oldest rendered")
    deleted = @bob.message!(@conversation, "deleted while away")
    kept = @alice.message!(@conversation, "still here")
    cursor = cursor_after(kept)
    deleted.soft_delete!

    login_as @alice
    freeze_time do
      get "/messages/#{@conversation.id}/refresh",
          params: cursor.merge(from: microseconds(oldest.created_at)),
          headers: { "Accept" => TURBO_STREAM }

      prune = css_select("turbo-stream[action='chats_prune']").sole
      assert_equal dom_id(@conversation, :history), prune["target"]
      assert_equal [oldest, kept].map { |message| dom_id(message) }, prune["data-ids"].split
      assert_not_includes prune["data-ids"], dom_id(before_window), "bounded by the oldest rendered bubble"
      assert_equal microseconds(10.seconds.ago), Integer(prune["data-until"]),
                   "a message whose insert hadn't committed when the list was read is never taken for a deleted one"
    end
  end

  test "soft deletion replaces a tombstone and needs no list of what exists" do
    message = @bob.message!(@conversation, "regret")
    cursor = cursor_after(message)
    travel 1.second
    message.soft_delete!

    login_as @alice
    get "/messages/#{@conversation.id}/refresh",
        params: cursor.merge(from: microseconds(message.created_at)),
        headers: { "Accept" => TURBO_STREAM }

    assert css_select("turbo-stream[action='replace'][target='#{dom_id(message)}']").one?
    assert_empty css_select("turbo-stream[action='chats_prune']")
  end

  test "the catch-up is the participant's own: outsiders and blocked pairs get a plain 404" do
    message = @bob.message!(@conversation, "only for the two of us")
    carol = create_user(name: "Carol")

    login_as carol
    get "/messages/#{@conversation.id}/refresh", params: { since: 1, from: 1 }, headers: { "Accept" => TURBO_STREAM }
    assert_response :not_found

    block_pair!(@alice, @bob)
    login_as @alice
    get "/messages/#{@conversation.id}/refresh", params: cursor_after(message),
                                                 headers: { "Accept" => TURBO_STREAM }
    assert_response :not_found
  end

  # --- the markup the catch-up hangs on -------------------------------------------------

  test "every bubble carries the cursors the catch-up sends, and the history the deep catch-up re-renders has an id" do
    message = @bob.message!(@conversation, "hola")
    login_as @alice

    get "/messages/#{@conversation.id}"

    bubble = css_select("##{dom_id(message)}").sole
    assert_equal (message.updated_at.to_f * 1000).ceil, Integer(bubble["data-updated-at-ms"])
    assert_equal microseconds(message.reload.created_at), Integer(bubble["data-created-at-us"])
    assert_select "##{dom_id(@conversation, :history)}.chats-thread__scroll[data-chats--thread-target='scroller']" do
      assert_select "##{dom_id(@conversation, :messages)}"
      assert_select "##{dom_id(@conversation, :read_state)}"
    end
  end

  test "the inbox's search keeps its query in the URL, so a refresh re-renders the same results" do
    login_as @alice
    get "/messages"

    assert_select "form.chats-search[data-turbo-frame='chats_inbox_results'][data-turbo-action='replace']"
  end

  test "the dock's list reloads by morphing, and the dock knows where its badges are" do
    login_as @alice
    get "/"

    assert_select "turbo-frame#chats_dock_list[refresh='morph']"
    assert_select "aside.chats-dock[data-chats--dock-badge-url-value='/messages/badge']"
  end

  test "a new message's inbox refresh names no request: it may stand for other requests' writes too" do
    login_as @bob
    post "/messages/#{@conversation.id}/messages", params: { message: { body: "from my tab" } },
                                                   headers: { "X-Turbo-Request-Id" => "tab-42" }

    streams = capture_turbo_stream_broadcasts([@bob, :chats_inbox]) do
      perform_enqueued_jobs only: Chats::InboxRefreshJob
    end
    assert_nil streams.sole["request-id"],
               "a tab that skipped it as its own would miss what others wrote in the same window"
  end

  private

  def appended_ids(append)
    css_select(append, "[data-chats--thread-target='message']").map { |node| node["id"] }
  end

  def actions_and_targets(streams)
    streams.map { |stream| [stream["action"], stream["target"]] }
  end

  # The client's cursors when +message+ is the newest bubble it rendered,
  # exactly as the bubble partial emits them.
  def cursor_after(message)
    message.reload
    { since: (message.updated_at.to_f * 1000).ceil, after: microseconds(message.created_at) }
  end

  def microseconds(time)
    (time.to_i * 1_000_000) + time.usec
  end
end
