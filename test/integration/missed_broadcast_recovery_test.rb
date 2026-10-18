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
    cursors = rendered.merge(cursor_after(shown).slice(:changed, :changed_ids)) # the edit came in live

    login_as @alice
    get "/messages/#{@conversation.id}/refresh", params: cursors, headers: { "Accept" => TURBO_STREAM }

    append = css_select("turbo-stream[action='append']").sole
    assert_equal [dom_id(missed)], appended_ids(append)
    assert_empty css_select("turbo-stream[action='replace'][target='#{dom_id(shown)}']"),
                 "the edit it already has isn't sent again"
  end

  test "a missed message created in the same instant as the newest bubble on screen comes, and that bubble only once" do
    shown, missed = travel_to(Time.zone.parse("2026-10-18 10:00:00.123456"), with_usec: true) do
      [@bob.message!(@conversation, "shown"), @bob.message!(@conversation, "missed, same instant")]
    end
    assert_equal shown.reload.created_at, missed.reload.created_at, "one timestamp, two messages"

    login_as @alice
    get "/messages/#{@conversation.id}/refresh", params: cursor_after(shown), headers: { "Accept" => TURBO_STREAM }

    append = css_select("turbo-stream[action='append']").sole
    assert_equal [dom_id(missed)], appended_ids(append)
    assert_empty css_select("turbo-stream[action='replace'][target='#{dom_id(shown)}']")
  end

  test "a missed change inside the same millisecond as the newest change on screen still comes" do
    shown = @bob.message!(@conversation, "shown")
    other = @bob.message!(@conversation, "other")
    travel_to(Time.zone.parse("2026-10-18 10:20:00.000100"), with_usec: true) { shown.edit!("seen at .000100") }
    rendered = cursor_after(other).merge(cursor_after(shown).slice(:changed, :changed_ids))
    travel_to(Time.zone.parse("2026-10-18 10:20:00.000700"), with_usec: true) { other.edit!("missed at .000700") }
    assert_equal 600, microseconds(other.reload.updated_at) - microseconds(shown.reload.updated_at),
                 "two changes inside one millisecond"

    login_as @alice
    get "/messages/#{@conversation.id}/refresh", params: rendered, headers: { "Accept" => TURBO_STREAM }

    assert_equal [dom_id(other)], replaced_messages
    assert_includes response.body, "missed at .000700"
  end

  test "a missed change in the very same microsecond as the change on screen still comes; the one on screen doesn't" do
    shown = @bob.message!(@conversation, "shown")
    other = @bob.message!(@conversation, "other")
    rendered = cursor_after(other)
    travel_to(Time.zone.parse("2026-10-18 10:20:00.000500"), with_usec: true) do
      shown.edit!("seen")
      other.edit!("missed, same microsecond")
    end
    rendered = rendered.merge(changed: microseconds(shown.reload.updated_at), changed_ids: shown.id.to_s)
    assert_equal shown.updated_at, other.reload.updated_at

    login_as @alice
    get "/messages/#{@conversation.id}/refresh", params: rendered, headers: { "Accept" => TURBO_STREAM }

    assert_equal [dom_id(other)], replaced_messages
  end

  test "bubbles ejected before the microsecond cursors are answered on the one cursor they had" do
    shown = @bob.message!(@conversation, "shown")
    since = (shown.reload.updated_at.to_f * 1000).ceil
    travel 1.second
    missed = @bob.message!(@conversation, "missed")

    login_as @alice
    get "/messages/#{@conversation.id}/refresh", params: { since: since }, headers: { "Accept" => TURBO_STREAM }

    assert_equal [dom_id(missed)], appended_ids(css_select("turbo-stream[action='append']").sole)
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
    get "/messages/#{@conversation.id}/refresh", params: { after: 0, changed: 0 }, headers: { "Accept" => TURBO_STREAM }

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

  test "an up-to-date client gets the read state and its cursors back, and nothing else" do
    message = @bob.message!(@conversation, "all caught up")
    cursors = cursor_after(message)

    login_as @alice
    get "/messages/#{@conversation.id}/refresh", params: cursors, headers: { "Accept" => TURBO_STREAM }

    expected = [["replace", dom_id(@conversation, :read_state)], ["chats_caught_up", dom_id(@conversation, :messages)]]
    assert_equal expected, actions_and_targets(css_select("turbo-stream"))
    assert_equal({ after: cursors[:after], changed: cursors[:changed], changed_ids: [message.id.to_s] }, caught_up)
  end

  test "the answer names the render that asked, so a later render of the thread can ignore it" do
    message = @bob.message!(@conversation, "hola")
    login_as @alice

    get "/messages/#{@conversation.id}/refresh", params: cursor_after(message).merge(render: "lq3r9a1x2b"),
                                                 headers: { "Accept" => TURBO_STREAM }
    assert_equal "lq3r9a1x2b", css_select("turbo-stream[action='chats_caught_up']").sole["data-render"]

    get "/messages/#{@conversation.id}/refresh",
        params: cursor_after(message).merge(render: "r" * 500, history: 1, full: 1),
        headers: { "Accept" => TURBO_STREAM }
    assert_equal "r" * 64, css_select("turbo-stream[action='chats_caught_up']").sole["data-render"],
                 "a history re-render names it too; never more than an id's length of it"

    get "/messages/#{@conversation.id}/refresh", params: cursor_after(message), headers: { "Accept" => TURBO_STREAM }
    assert_nil css_select("turbo-stream[action='chats_caught_up']").sole["data-render"]
  end

  test "the answer moves the cursors to what it sent: the newest creation and the newest change in it" do
    shown = @bob.message!(@conversation, "shown")
    cursors = cursor_after(shown)
    travel 1.second
    appended = @bob.message!(@conversation, "missed")
    travel 1.second
    shown.edit!("edited while away")

    login_as @alice
    get "/messages/#{@conversation.id}/refresh", params: cursors, headers: { "Accept" => TURBO_STREAM }

    assert_equal({ after: microseconds(appended.reload.created_at), changed: microseconds(shown.reload.updated_at),
                   changed_ids: [shown.id.to_s] }, caught_up)
  end

  # --- what arrived live never moves the cursors (the client keeps them; these
  # are what it sends after a live bubble, and what it gets back) -------------

  test "a message missed, then one live: the missed one comes, the live one isn't sent again" do
    shown = travel_to(Time.zone.parse("2026-10-18 10:00")) { @bob.message!(@conversation, "shown") }
    rendered = cursor_after(shown)
    missed = travel_to(Time.zone.parse("2026-10-18 10:15")) { @bob.message!(@conversation, "missed at 10:15") }
    arrived = travel_to(Time.zone.parse("2026-10-18 10:20")) { @bob.message!(@conversation, "live at 10:20") }

    login_as @alice
    get "/messages/#{@conversation.id}/refresh",
        params: rendered.merge(after_ids: [shown.id, arrived.id].join(",")), # the cursor stays at 10:00; 10:20 is named
        headers: { "Accept" => TURBO_STREAM }

    assert_equal [dom_id(missed)], appended_ids(css_select("turbo-stream[action='append']").sole)
  end

  test "an edit missed, then one live: the missed one comes" do
    # Written before the edits: created at the real "now", they would
    # postdate the 10:15 edit on any day after the test was written.
    shown = travel_to(Time.zone.parse("2026-10-18 10:00")) { @bob.message!(@conversation, "shown") }
    other = travel_to(Time.zone.parse("2026-10-18 10:01")) { @bob.message!(@conversation, "other") }
    rendered = cursor_after(other)
    travel_to(Time.zone.parse("2026-10-18 10:15")) { shown.edit!("missed edit at 10:15") }
    travel_to(Time.zone.parse("2026-10-18 10:20")) { other.edit!("live edit at 10:20") }

    login_as @alice
    get "/messages/#{@conversation.id}/refresh", params: rendered, headers: { "Accept" => TURBO_STREAM }

    assert_includes replaced_messages, dom_id(shown)
    assert_includes response.body, "missed edit at 10:15"
  end

  # --- cursors past the limit -----------------------------------------------------

  test "cursors naming more than 200 ids, or an id longer than any key, get the whole history instead" do
    shown = @bob.message!(@conversation, "shown")
    login_as @alice

    [
      cursor_after(shown).merge(after_ids: Array.new(201) { |index| index + 1 }.join(",")),
      cursor_after(shown).merge(changed_ids: Array.new(201) { |index| index + 1 }.join(",")),
      cursor_after(shown).merge(after_ids: "9" * 65),
      cursor_after(shown).merge(full: 1)
    ].each do |cursors|
      get "/messages/#{@conversation.id}/refresh", params: cursors.merge(history: 1),
                                                   headers: { "Accept" => TURBO_STREAM }
      assert_equal [["update", dom_id(@conversation, :history)], ["chats_caught_up", dom_id(@conversation, :messages)]],
                   actions_and_targets(css_select("turbo-stream")), cursors.keys.inspect

      get "/messages/#{@conversation.id}/refresh", params: cursors, headers: { "Accept" => TURBO_STREAM }
      assert_equal %(<turbo-stream action="refresh"></turbo-stream>), response.body.strip,
                   "a thread ejected before the history had its id gets the page refresh"
    end

    get "/messages/#{@conversation.id}/refresh",
        params: cursor_after(shown).merge(after_ids: Array.new(200) { |index| index + 1 }.join(",")),
        headers: { "Accept" => TURBO_STREAM }
    assert css_select("turbo-stream[action='chats_caught_up']").one?, "200 is still an incremental catch-up"
    assert_empty css_select("turbo-stream[action='update']")
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
    assert_equal message.id.to_s, bubble["data-message-id"]
    assert_equal microseconds(message.reload.updated_at), Integer(bubble["data-updated-at-us"])
    assert_nil bubble["data-updated-at-ms"], "the millisecond cursor is only an ejected bubble's"
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

  # The cursors the answer leaves the client at (its chats_caught_up action).
  def caught_up
    tag = css_select("turbo-stream[action='chats_caught_up']").sole
    { after: Integer(tag["data-after"]), changed: Integer(tag["data-changed"]),
      changed_ids: tag["data-changed-ids"].split(",") }
  end

  # The bubbles a catch-up replaced (the read state is always replaced).
  def replaced_messages
    targets = css_select("turbo-stream[action='replace']").map { |stream| stream["target"] }
    targets - [dom_id(@conversation, :read_state)]
  end

  def appended_ids(append)
    css_select(append, "[data-chats--thread-target='message']").map { |node| node["id"] }
  end

  def actions_and_targets(streams)
    streams.map { |stream| [stream["action"], stream["target"]] }
  end

  # The client's cursors when +message+ is the newest bubble it rendered
  # and the last one changed, exactly as the thread controller sends them.
  def cursor_after(message)
    message.reload
    { after: microseconds(message.created_at), after_ids: message.id.to_s,
      changed: microseconds(message.updated_at), changed_ids: message.id.to_s }
  end

  def microseconds(time)
    (time.to_i * 1_000_000) + time.usec
  end
end
