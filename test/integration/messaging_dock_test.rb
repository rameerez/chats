# frozen_string_literal: true

require "test_helper"

# The messaging dock through the full request cycle: the host page that
# renders it, its recent list, its floating windows, and the Message button
# that opens one.
class MessagingDockTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier

  setup do
    @alice = create_user(name: "Alice")
    @bob = create_user(name: "Bob")
    @carol = create_user(name: "Carol")
    @conversation = conversation_between(@alice, @bob)
  end

  # --- the dock on a host page ------------------------------------------------

  test "a host page renders the dock: permanent, with its windows, panel, badge and live stream" do
    @bob.message!(@conversation, "hola")
    login_as @alice

    get "/"

    assert_response :success
    assert_select "aside#chats_dock.chats-dock[data-turbo-permanent][data-controller='chats--dock']" do
      assert_select "turbo-cable-stream-source", 1
      assert_select "#chats_dock_windows[data-chats--dock-target='windows']:empty"
      assert_select "details.chats-dock__panel summary.chats-dock__bar", 1
      assert_select "#chats_dock_badge", text: /1/
      assert_select "turbo-frame#chats_dock_list[loading='lazy'][target='_top'][src='/messages/dock?recent=10']"
      assert_select "form.chats-dock__search[data-turbo-frame='chats_dock_list'][action='/messages/dock']"
      assert_select "a.chats-dock__see-all[href='/messages/']", text: "See all messages"
    end
  end

  test "the dock remembers windows per messager and knows where windows load from" do
    login_as @alice
    get "/"

    dock = css_select("#chats_dock").first
    assert_equal "chats:dock:#{Chats.messager_key(@alice)}", dock["data-chats--dock-storage-key-value"]
    assert_equal "/messages/__id__?window=1", dock["data-chats--dock-window-url-value"]
    assert_equal "3", dock["data-chats--dock-windows-value"]
  end

  test "the dock never renders on the engine's own pages" do
    @bob.message!(@conversation, "hola")
    login_as @alice

    get "/messages"
    assert_response :success
    assert_empty css_select("#chats_dock"), "the inbox already is the messaging UI"

    get "/messages/#{@conversation.id}"
    assert_response :success
    assert_empty css_select("#chats_dock"), "a window there would duplicate the thread's ids"
  end

  test "a signed-out visitor gets no dock" do
    get "/"

    assert_response :success
    assert_empty css_select("#chats_dock")
  end

  test "the dock's Message button posts dock=1" do
    login_as @alice
    get "/"

    assert_select "form[action='/messages/'] input[name='dock'][value='1']", 2 # Bob and Carol
  end

  test "the dock_panel_footer slot puts a host link beside See all messages" do
    login_as @alice

    with_slot_views { get "/" }

    assert_select ".chats-dock__footer a[data-dummy-slot='dock_panel_footer']", text: "Help for Alice"
  end

  test "the dock has no search field when search is off" do
    Chats.config.search = false
    login_as @alice

    get "/"

    assert_select "#chats_dock"
    assert_empty css_select(".chats-dock__search")
  end

  # --- the recent list ----------------------------------------------------------

  test "the recent list is the viewer's inbox rows, in a frame, without a layout" do
    @bob.message!(@conversation, "are you coming?")
    login_as @alice

    get "/messages/dock"

    assert_response :success
    assert_not_includes response.body, "<html", "a frame response, not a page"
    assert_select "turbo-frame#chats_dock_list[target='_top']" do
      assert_select "li.chats-row.chats-row--unread", 1
      link = css_select("a.chats-row__link").first
      assert_equal "/messages/#{@conversation.id}", link["href"], "a real link to the thread"
      assert_equal "chats--dock#open", link["data-action"]
      assert_equal @conversation.id.to_s, link["data-chats--dock-id-param"]
    end
    assert_includes response.body, "are you coming?"
  end

  test "the recent list never shows another messager's conversations" do
    outsider = conversation_between(@bob, @carol)
    @carol.message!(outsider, "between us")
    @bob.message!(@conversation, "hola Alice")
    login_as @alice

    get "/messages/dock"

    assert_not_includes response.body, "/messages/#{outsider.id}"
    assert_not_includes response.body, "between us"
  end

  test "the recent list never shows a conversation nobody has written in" do
    login_as @alice # @conversation was only opened

    get "/messages/dock"

    assert_empty css_select("li.chats-row")
    assert_select ".chats-dock__empty", text: "No conversations yet"
  end

  test "the recent list honours inbox_scope and blocks" do
    @bob.message!(@conversation, "blocked soon")
    scoped = @carol.message!(@alice, "scoped out").conversation
    Chats.config.inbox_scope = ->(relation, _viewer) { relation.where.not(id: scoped.id) }
    block_pair!(@alice, @bob)
    login_as @alice

    get "/messages/dock"

    assert_empty css_select("li.chats-row")
  end

  test "the recent list shows `recent` rows, newest first, and caps what it is asked" do
    people = Array.new(4) { |index| create_user(name: "Person #{index}") }
    conversations = people.map { |person| person.message!(@alice, "hi").conversation }
    login_as @alice

    get "/messages/dock", params: { recent: 2 }
    assert_equal 2, css_select("li.chats-row").size
    assert_includes response.body, "/messages/#{conversations.last.id}"
    assert_not_includes response.body, "/messages/#{conversations.first.id}\""

    get "/messages/dock"
    assert_equal 4, css_select("li.chats-row").size, "ten by default"

    get "/messages/dock", params: { recent: "nonsense" }
    assert_response :success

    get "/messages/dock", params: { recent: 10_000 }
    assert_response :success
  end

  test "the recent list searches the whole inbox, not just its own rows" do
    old = @bob.message!(@alice, "the code for the trunk is 4242").conversation
    Array.new(3) { |index| create_user(name: "Recent #{index}").message!(@alice, "newer") }
    login_as @alice

    get "/messages/dock", params: { recent: 2, q: "trunk" }

    assert_equal 1, css_select("li.chats-row").size
    assert_includes response.body, "/messages/#{old.id}"

    get "/messages/dock", params: { q: "zzz-nothing" }
    assert_select ".chats-dock__empty", text: /zzz-nothing/
  end

  test "in the recent list a stack of one opens its window, a deeper stack goes to the stack" do
    desk = create_desk(name: "Soporte")
    single = desk.message!(@alice, "ticket").conversation
    login_as @alice

    get "/messages/dock"
    link = css_select("li.chats-row--group a").first
    assert_equal single.id.to_s, link["data-chats--dock-id-param"]

    desk.message!(@alice, "another", about: create_listing(title: "Second"))
    get "/messages/dock"
    link = css_select("li.chats-row--group a").first
    assert_nil link["data-action"], "a stack opens the stack list, not a window"
    assert_includes link["href"], "with="
  end

  test "the recent list requires a viewer" do
    get "/messages/dock"

    assert_response :unauthorized
  end

  # --- a window -------------------------------------------------------------------

  test "a window is the thread body in its frame, with the compact header and no layout" do
    @bob.message!(@conversation, "unread for Alice")
    login_as @alice

    get_window @conversation

    assert_response :success
    assert_not_includes response.body, "<html"
    assert_select "turbo-frame##{dom_id(@conversation, :window)}" do
      assert_select ".chats-window__card[aria-label='Bob']" do
        assert_select "[data-controller='chats--thread'][data-chats--thread-read-pending-value='true']" do
          assert_select "turbo-cable-stream-source"
          assert_select "header.chats-window__header" do
            assert_select ".chats-window__name", text: "Bob"
            assert_select "a.chats-window__expand[href='/messages/#{@conversation.id}'][data-turbo-frame='_top']"
            assert_select "button.chats-window__minimize[data-action='chats--dock#minimize'][aria-expanded='true']"
            assert_select "button.chats-window__close[data-action='chats--dock#close'][aria-label='Close conversation']"
            assert_select "button.chats-window__back[data-action='chats--dock#back']"
          end
          assert_select "##{dom_id(@conversation, :messages)}", text: /unread for Alice/
          assert_select ".chats-thread__unread-line"
          assert_select ".chats-popup[hidden]"
          assert_select "##{dom_id(@conversation, :composer)} form.chats-composer__form"
        end
      end
    end
    assert_empty css_select(".chats-thread__header"), "the page's header stays on the page"
  end

  test "a window does not read on render: it reads once it is on screen" do
    @bob.message!(@conversation, "unread")
    login_as @alice

    get_window @conversation

    assert_equal 1, @alice.unread_chats_count, "a window restored minimized must not swallow the badge"
  end

  test "without a frame the same URL is the thread page, which reads" do
    @bob.message!(@conversation, "unread")
    login_as @alice

    get "/messages/#{@conversation.id}", params: { window: 1 }

    assert_select "html"
    assert_select ".chats-thread__header"
    assert_equal 0, @alice.unread_chats_count
  end

  test "a window of an empty conversation opens: that is where its first message is written" do
    login_as @alice

    get_window @conversation

    assert_response :success
    assert_select "##{dom_id(@conversation, :composer)} textarea"
  end

  test "a window is a 404 for an outsider and for a blocked pair" do
    login_as @carol
    get_window @conversation
    assert_response :not_found

    block_pair!(@alice, @bob)
    login_as @alice
    get_window @conversation
    assert_response :not_found
  end

  test "a locked conversation's window shows the locked composer" do
    listing = create_listing(title: "Closed listing", locked: true)
    locked = conversation_between(@alice, @bob, about: listing)
    login_as @alice

    get_window locked

    assert_response :success
    assert_select ".chats-composer--locked", text: /This listing is closed/
    assert_empty css_select("form.chats-composer__form")
    assert_select ".chats-window__subject", text: "Closed listing"
  end

  test "a group window is named after the group" do
    group = Chats::Conversation.group!(@alice, [@bob, @carol], title: "Trip")
    login_as @alice

    get_window group

    assert_select ".chats-window__name", text: "Trip"
  end

  test "the thread page renders the same body, read on render" do
    login_as @alice

    get "/messages/#{@conversation.id}"

    assert_select "[data-controller='chats--thread'][data-chats--thread-read-pending-value='false']" do
      assert_select ".chats-thread__header"
      assert_select "##{dom_id(@conversation, :composer)}"
    end
  end

  # --- the Message button, dock: true ---------------------------------------------

  test "dock=1 from Turbo appends the conversation's window to the dock" do
    login_as @alice

    post "/messages", params: { recipient_sgid: sgid_for(@carol), dock: 1 },
                      headers: { "Accept" => "text/vnd.turbo-stream.html, text/html" }

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    conversation = Chats::Conversation.direct_between(@alice, @carol)
    assert_select "turbo-stream[action='append'][target='chats_dock_windows'] template" do
      frame = css_select("turbo-frame").first
      assert_equal dom_id(conversation, :window), frame["id"]
      assert_equal "/messages/#{conversation.id}?window=1", frame["src"]
      assert_equal "_top", frame["target"]
      assert_equal "window", frame["data-chats--dock-target"]
      assert_equal conversation.id.to_s, frame["data-conversation-id"]
      assert frame.key?("data-focus"), "opened by a click: the composer takes the focus"
    end
  end

  test "without dock the button still navigates to the thread" do
    login_as @alice

    post "/messages", params: { recipient_sgid: sgid_for(@bob) },
                      headers: { "Accept" => "text/vnd.turbo-stream.html, text/html" }
    assert_redirected_to "/messages/#{@conversation.id}"

    post "/messages", params: { recipient_sgid: sgid_for(@bob), dock: 1 } # no Turbo
    assert_redirected_to "/messages/#{@conversation.id}"
  end

  test "dock=1 still refuses a blocked pair the usual way" do
    block_pair!(@alice, @bob)
    login_as @alice

    post "/messages", params: { recipient_sgid: sgid_for(@bob), dock: 1 },
                      headers: { "Accept" => "text/vnd.turbo-stream.html, text/html" }

    assert_redirected_to "/messages/"
    assert_equal I18n.t("chats.flashes.blocked"), flash[:alert]
  end

  private

  SLOT_VIEWS = File.expand_path("../fixtures/slot_views", __dir__)

  # The dock renders in the HOST's controller, so the fixture slot goes on
  # the host's view path.
  def with_slot_views
    original = ApplicationController.view_paths
    ApplicationController.prepend_view_path(SLOT_VIEWS)
    yield
  ensure
    ApplicationController.view_paths = original
  end

  # What a dock window's turbo frame sends.
  def get_window(conversation)
    get "/messages/#{conversation.id}", params: { window: 1 },
                                        headers: { "Turbo-Frame" => dom_id(conversation, :window) }
  end

  def sgid_for(messager)
    messager.to_sgid(expires_in: nil, for: :chats_recipient).to_s
  end
end
