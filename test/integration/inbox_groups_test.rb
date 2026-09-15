# frozen_string_literal: true

require "test_helper"

# The inbox, through the full request cycle: stacked rows, the `?with=`
# filtered inbox, and the "see all" way back from a stacked thread.
class InboxGroupsTest < ActionDispatch::IntegrationTest
  setup do
    @alice = create_user(name: "Alice")
    @bob = create_user(name: "Bob")
    @desk = create_desk(name: "Soporte")
  end

  test "three desk conversations render as ONE row with the aggregate badge" do
    3.times do |index|
      conversation = @alice.chat_with(@desk, about: create_listing(title: "Listing #{index}"))
      @desk.message!(conversation, "ticket #{index}")
    end
    login_as @alice

    get "/messages"

    assert_response :success
    assert_equal 1, css_select("li.chats-row--group").size
    assert_equal 1, css_select("li.chats-row").size, "the stack replaces its conversations, it doesn't add to them"
    assert_includes response.body, "Soporte"
    assert_includes response.body, "3 conversations"
    assert_equal "3", css_select("li.chats-row--group .chats-badge").first.text
  end

  test "a deep stack links to the filtered inbox, which lists its conversations" do
    stack = Array.new(2) do |index|
      @alice.chat_with(@desk, about: create_listing(title: "Listing #{index}"))
    end
    login_as @alice

    get "/messages"
    href = css_select("li.chats-row--group a").first["href"]

    assert_includes href, "with="

    get href
    assert_response :success
    assert_equal 2, css_select("li.chats-row").size
    assert_empty css_select("li.chats-row--group")
    stack.each { |conversation| assert_includes response.body, "/messages/#{conversation.id}" }
    assert_includes response.body, "Conversations with Soporte"
  end

  test "a stack of one links straight to the thread, which links back to the stack" do
    conversation = @alice.chat_with(@desk)
    @desk.message!(conversation, "just the one")
    login_as @alice

    get "/messages"
    assert_equal "/messages/#{conversation.id}", css_select("li.chats-row--group a").first["href"]

    get "/messages/#{conversation.id}"
    assert_response :success
    see_all = css_select(".chats-thread__see-all-link").first
    assert_equal "See all", see_all.text
    assert_includes see_all["href"], "with="
  end

  test "an ordinary thread offers no see-all link" do
    conversation = @alice.chat_with(@bob)
    login_as @alice

    get "/messages/#{conversation.id}"

    assert_empty css_select(".chats-thread__see-all-link")
  end

  test "group_path: sends the stacked row wherever the host wants" do
    with_desk_group_path(->(viewer) { "/custom/desk/#{viewer.id}" }) do
      2.times { |index| @alice.chat_with(@desk, about: create_listing(title: "L#{index}")) }
      login_as @alice

      get "/messages"

      assert_response :success
      assert_equal "/custom/desk/#{@alice.id}", css_select("li.chats-row--group a").first["href"]
    end
  end

  test "group_path: also drives the see-all link out of a stacked thread" do
    with_desk_group_path(->(_viewer) { "/custom/desk" }) do
      conversation = @alice.chat_with(@desk)
      login_as @alice

      get "/messages/#{conversation.id}"

      assert_response :success
      assert_equal "/custom/desk", css_select(".chats-thread__see-all-link").first["href"]
    end
  end

  test "a tampered or wrong-purpose with= is a plain 404" do
    @alice.chat_with(@desk)
    login_as @alice

    get "/messages", params: { with: "not-a-signed-global-id" }
    assert_response :not_found

    get "/messages", params: { with: @desk.to_sgid(for: :chats_recipient).to_s }
    assert_response :not_found
  end

  test "the filtered inbox never leaks conversations the viewer isn't in" do
    outsider_thread = @bob.chat_with(@desk)
    @alice.chat_with(@desk)
    login_as @alice

    get "/messages", params: { with: Chats.inbox_with_sgid(@desk) }

    assert_response :success
    assert_not_includes response.body, "/messages/#{outsider_thread.id}"
  end

  test "a stacked counterpart's own inbox stays flat" do
    @alice.chat_with(@desk)
    @bob.chat_with(@desk)
    login_as @desk

    get "/messages"

    assert_response :success
    assert_empty css_select("li.chats-row--group"), "stacking is about the COUNTERPART, not the viewer"
    assert_equal 2, css_select("li.chats-row").size
  end

  test "the controller still assigns @conversations for inboxes ejected under 0.1.x" do
    conversation = @alice.chat_with(@bob)
    login_as @alice

    get "/messages"

    assert_response :success
    assert_equal [conversation], @controller.view_assigns["conversations"]
  end

  test "the counterpart is resolved once per thread, and not at all for a group" do
    direct = @alice.chat_with(@bob)
    group = @alice.chat_with(@bob, @desk, title: "Trip")
    login_as @alice

    # The header names the counterpart, links to their profile, draws their
    # avatar and decides on the "see all" link — one lookup serves all four.
    lookups = count_counterpart_lookups { get "/messages/#{direct.id}" }
    assert_response :success
    assert_equal 1, lookups

    assert_equal 0, count_counterpart_lookups { get "/messages/#{group.id}" },
                 "a group thread has no counterpart and must not go looking for one"
    assert_response :success
  end

  private

  # Count the "everyone in this conversation except me" query behind
  # ConversationsController#chats_counterpart.
  def count_counterpart_lookups(&block)
    found = 0
    counter = lambda do |*, payload|
      found += 1 if payload[:sql].to_s.match?(/FROM\s+.?chats_participants.?.*\bNOT\b/im)
    end

    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    found
  end

  # Declare a `group_path:` on the headless messager for one test. Assigning
  # the real class_attribute (rather than stubbing a reader) exercises the
  # same path `acts_as_messager group_path:` writes.
  def with_desk_group_path(callable)
    original = Desk.chat_options
    Desk.chat_options = original.merge(group_path: callable).freeze
    yield
  ensure
    Desk.chat_options = original
  end
end
