# frozen_string_literal: true

require "test_helper"

# The two-pane messaging page (`config.inbox_layout = :split`, the default):
# the list beside the open conversation, LinkedIn-style. Which pane shows at
# which width is one media query in chats.css, so what is tested here is the
# markup every request gets, the answers to each kind of request (a page, the
# pane's own frame, a prefetch, a Turbo visit) and when the server reads.
# The geometry, the frame navigation and the live refreshes run in headless
# Chrome (test/system/split_inbox_test.rb).
class SplitInboxTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier

  SLOT_VIEWS = File.expand_path("../fixtures/slot_views", __dir__)
  PANE_FRAME = { "Turbo-Frame" => "chats_conversation" }.freeze

  setup do
    @alice = create_user(name: "Alice")
    @bob = create_user(name: "Bob")
    @carol = create_user(name: "Carol")
    @conversation = conversation_between(@alice, @bob)
    @bob.message!(@conversation, "are you coming?")
    @other = conversation_between(@alice, @carol)
    @carol.message!(@other, "hola")
  end

  # --- /messages: the list and the empty pane ---------------------------------------

  test "the inbox is two panes: the list in a named nav, and the conversation frame with nothing open" do
    login_as @alice

    get "/messages"

    assert_response :success
    assert_select ".chats.chats-inbox.chats-split[data-chats-dock-hide][data-controller='chats--split']", 1 do
      assert_select "> nav.chats-split__list[aria-label='Messages'][data-chats--split-target='list']", 1 do
        assert_select "h1.chats-inbox__title", text: "Messages"
        assert_select "form.chats-search[role=search]"
        assert_select "turbo-frame#chats_inbox_results[target=_top] li.chats-row", 2
      end
      assert_select "> turbo-frame#chats_conversation.chats-split__conversation", 1 do |frames|
        frame = frames.first
        assert_equal "_top", frame["target"], "links in the pane open pages, not the frame"
        assert_equal "advance", frame["data-turbo-action"], "opening one moves the address bar"
        assert frame.key?("disabled"), "disabled until chats--split says the screen is wide"
        assert_nil frame["src"], "never lazy: the page renders what the frame holds"
        assert_equal "frame", frame["data-chats--split-target"]

        assert_select ".chats-split__empty:not(.chats-split__empty--inbox) .chats-empty__title",
                      text: "Select a conversation"
        assert_select ".chats-split__pane", 0
      end
    end
  end

  test "every row is a real link to its conversation, aimed at the frame, and none is current" do
    login_as @alice

    get "/messages"

    links = css_select(".chats-split__list a.chats-row__link")
    assert_equal(["/messages/#{@other.id}", "/messages/#{@conversation.id}"], links.map { |link| link["href"] })
    assert(links.all? { |link| link["data-turbo-frame"] == "chats_conversation" })
    assert(links.none? { |link| link.key?("aria-current") })
    assert_select ".chats-row--current", 0
  end

  test "the inbox's own stream and its reconciler sit outside both panes" do
    login_as @alice

    get "/messages"

    assert_select "[data-controller='chats--refresh-inbox'] turbo-cable-stream-source", 1
    assert_select ".chats-split [data-controller='chats--refresh-inbox']", 0
  end

  test "an empty inbox says so once, in the pane, with the inbox_empty slot, and nothing asks to select" do
    nobody = create_user(name: "Nobody")
    login_as nobody

    with_slot_views { get "/messages" }

    assert_response :success
    assert_select ".chats-split__list .chats-empty", 0, "not once in the list and again beside it"
    assert_select "#chats_conversation .chats-split__empty.chats-split__empty--inbox", 1 do
      assert_select ".chats-empty__title", text: "No conversations yet"
      assert_select ".chats-empty__hint", text: "When you start a conversation, it will show up here."
      assert_select "[data-dummy-slot=inbox_empty]", 1
    end
    assert_select "[data-dummy-slot=inbox_empty]", 1
    assert_not_includes response.body, "Select a conversation"
  end

  test "a search with no results says so in the list, and the pane still asks for a conversation" do
    login_as @alice

    get "/messages", params: { q: "zzz" }

    assert_select ".chats-split__list .chats-empty__title", text: "No results"
    assert_select "#chats_conversation .chats-split__empty:not(.chats-split__empty--inbox)", 1
  end

  test "the search form has no action, so it searches whatever page it is on, the open conversation's included" do
    login_as @alice

    get "/messages"
    form = css_select("form.chats-search").sole
    assert_not form.key?("action"), "a form without one submits to the page's current URL"
    assert_equal "get", form["method"]
    assert_equal "chats_inbox_results", form["data-turbo-frame"]
    assert_equal "replace", form["data-turbo-action"]

    get "/messages/#{@conversation.id}"
    assert_not css_select("form.chats-search").sole.key?("action")
  end

  # --- /messages/:id: the same page with the conversation open ------------------------

  test "a conversation's page is both panes: its row current, its thread in the pane" do
    login_as @alice

    get "/messages/#{@conversation.id}"

    assert_response :success
    assert_select ".chats-split > nav.chats-split__list li.chats-row", 2
    assert_select "li.chats-row.chats-row--current", 1 do
      assert_select "a.chats-row__link[href='/messages/#{@conversation.id}'][aria-current=page]"
    end
    assert_select "a[aria-current]", 1

    assert_select "#chats_conversation > section.chats-split__pane[data-conversation-id='#{@conversation.id}']", 1 do
      assert_select "> header.chats-thread__header", 1 do
        assert_select "a.chats-thread__back[href='/messages/']" # narrow screens only (chats.css)
        assert_select "h2.chats-thread__title#title_conversation_#{@conversation.id}", text: "Bob"
        assert_select "details.chats-menu button", text: "Mute"
      end
      assert_select "> .chats-split__thread[data-turbo-permanent] > .chats-thread.chats-thread--pane", 1 do
        assert_select "turbo-cable-stream-source", 1
        assert_select ".chats-thread__header", 0, "the header is the pane's, outside the permanent thread"
        assert_select "##{dom_id(@conversation, :messages)}", text: /are you coming\?/
        assert_select "##{dom_id(@conversation, :composer)} textarea"
      end
    end
    assert_equal "title_conversation_#{@conversation.id}",
                 css_select("section.chats-split__pane").sole["aria-labelledby"]
    assert_select ".chats-split__empty", 0
    assert_select "h1", 1, "the page's heading is the list's; the conversation's is under it"
  end

  test "the thread in the pane is the page's: not a .chats shell of its own, and it carries no dock-hide of its own" do
    login_as @alice

    get "/messages/#{@conversation.id}"

    thread = css_select(".chats-thread--pane").sole
    assert_not_includes thread["class"].split, "chats"
    assert_equal "chats--thread", thread["data-controller"]
    assert_equal "/messages/#{@conversation.id}", thread["data-chats--thread-thread-url-value"]
    assert_equal "/messages/#{@conversation.id}/refresh", thread["data-chats--thread-refresh-url-value"]
    assert_nil thread["data-chats-dock-hide"]
    assert_select "[data-chats-dock-hide]", 1, "the page says it once"
  end

  test "the pane's permanent id is keyed by the conversation and by the viewer" do
    login_as @alice
    get "/messages/#{@conversation.id}"
    with_bob = pane_id
    get "/messages/#{@other.id}"
    with_carol = pane_id

    login_as @bob
    get "/messages/#{@conversation.id}"
    bobs = pane_id

    assert_equal "chats_conversation_pane_#{@conversation.id}_#{Chats.messager_key(@alice)}", with_bob
    assert_equal "chats_conversation_pane_#{@other.id}_#{Chats.messager_key(@alice)}", with_carol
    assert_equal "chats_conversation_pane_#{@conversation.id}_#{Chats.messager_key(@bob)}", bobs
    assert_equal 3, [with_bob, with_carol, bobs].uniq.size,
                 "another conversation replaces the pane; another account never inherits it"
  end

  test "the pane carries the host's slots: the header actions, the composer actions" do
    login_as @alice

    with_slot_views { get "/messages/#{@conversation.id}" }

    assert_select ".chats-split__pane > header [data-dummy-slot=conversation_header_actions] .dummy-block-button", 1
    assert_select ".chats-thread--pane .chats-composer__actions [data-dummy-slot=composer_actions]", 1
  end

  test "a muted conversation's pane offers Unmute" do
    @conversation.participant_for(@alice).mute!
    login_as @alice

    get "/messages/#{@conversation.id}"

    assert_select ".chats-split__pane > header details.chats-menu button", text: "Unmute"
  end

  test "a stack of one is a link into the pane, and the current row while it is open; a deeper stack is not" do
    desk = create_desk(name: "Soporte")
    ticket = @alice.chat_with(desk, about: create_listing(title: "Listing 1"))
    desk.message!(ticket, "Ticket #1")
    login_as @alice

    get "/messages/#{ticket.id}"
    stack = css_select("li.chats-row--group").sole
    assert_includes stack["class"].split, "chats-row--current"
    link = css_select(stack, "a.chats-row__link").sole
    assert_equal "chats_conversation", link["data-turbo-frame"]
    assert_equal "page", link["aria-current"]

    desk.message!(@alice.chat_with(desk, about: create_listing(title: "Listing 2")), "Ticket #2")
    get "/messages/#{ticket.id}"
    deep = css_select("li.chats-row--group a.chats-row__link").sole
    assert_nil deep["data-turbo-frame"], "the stack list is a page"
    assert_nil deep["aria-current"]
  end

  test "a search from the open conversation's page filters the list and keeps the conversation open" do
    login_as @alice

    get "/messages/#{@conversation.id}", params: { q: "Carol" }

    assert_select ".chats-split__list li.chats-row", 1
    assert_select ".chats-split__list li.chats-row", text: /Carol/
    assert_select "section.chats-split__pane[data-conversation-id='#{@conversation.id}']", 1
    assert_select "input[name=q][value=Carol]"
  end

  test "a filtered list's rows keep its filter in their links, so the list's refreshes find the same list" do
    login_as @alice

    get "/messages", params: { q: "Bob" }
    assert_equal(["/messages/#{@conversation.id}?q=Bob"], css_select("a.chats-row__link").map { |link| link["href"] })

    desk = create_desk(name: "Soporte")
    tickets = Array.new(2) do |index|
      ticket = @alice.chat_with(desk, about: create_listing(title: "Listing #{index}"))
      desk.message!(ticket, "ticket #{index}")
      ticket
    end
    get "/messages"
    stack = css_select("li.chats-row--group a").sole["href"]

    get stack
    with = Rack::Utils.parse_query(URI(stack).query).fetch("with")
    hrefs = css_select("a.chats-row__link").map { |link| link["href"] }
    assert_equal tickets.reverse.map { |ticket| "/messages/#{ticket.id}?with=#{CGI.escape(with)}" }, hrefs

    get hrefs.first # what the frame advanced the address bar to, and what a refresh re-requests
    assert_select ".chats-inbox__filter", text: /Soporte/
    assert_equal hrefs, css_select("a.chats-row__link").map { |link| link["href"] }, "still the stack, not the inbox"
    current = css_select("li.chats-row--current a[aria-current=page]").sole
    assert_equal hrefs.first, current["href"]
    back = css_select(".chats-split__pane a.chats-thread__back").sole["href"]
    assert_equal "/messages/?with=#{CGI.escape(with)}", back, "back on a phone goes to the stack it came from"
  end

  test "the stacked layout's rows stay bare links: their list has no pane to keep" do
    Chats.config.inbox_layout = :stacked
    login_as @alice

    get "/messages", params: { q: "Bob" }

    assert_equal(["/messages/#{@conversation.id}"], css_select("a.chats-row__link").map { |link| link["href"] })
  end

  test "the pane's title can take the focus, for the touch screens chats--split sends it to" do
    login_as @alice

    get "/messages/#{@conversation.id}"

    assert_equal "-1", css_select(".chats-split__pane h2.chats-thread__title").sole["tabindex"]
  end

  # --- the page's title -----------------------------------------------------------------

  test "the bundled pages give the layout their title: the inbox's, the open conversation's" do
    login_as @alice

    get "/messages"
    assert_equal "Messages", css_select("head title").sole.text

    get "/messages/#{@conversation.id}"
    assert_equal "Bob · Messages", css_select("head title").sole.text
    assert_equal "Bob · Messages", css_select("section.chats-split__pane").sole["data-title"],
                 "one source: the full page's title and the pane's are the same"

    Chats.config.inbox_layout = :stacked
    get "/messages/#{@conversation.id}"
    assert_equal "Bob · Messages", css_select("head title").sole.text
  end

  test "config.page_title words both, the inbox (no conversation) and a conversation, in the viewer's terms" do
    Chats.config.page_title = lambda { |conversation, viewer|
      [viewer.name, conversation&.title_for(viewer)].compact.join(" ↔ ")
    }
    login_as @alice

    get "/messages"
    assert_equal "Alice", css_select("head title").sole.text

    get "/messages/#{@conversation.id}", headers: PANE_FRAME.merge(turbo_request)
    assert_equal "Alice ↔ Bob", css_select("section.chats-split__pane").sole["data-title"]
  end

  test "a config.page_title that answers nothing falls back to the gem's wording" do
    Chats.config.page_title = ->(_conversation, _viewer) {}
    login_as @alice

    get "/messages/#{@conversation.id}"

    assert_equal "Bob · Messages", css_select("head title").sole.text
  end

  test "the page's title is localized" do
    login_as @alice

    I18n.with_locale(:es) { get "/messages/#{@conversation.id}" }

    assert_equal "Bob · Mensajes", css_select("head title").sole.text
  end

  test "a config.layout never wraps the pane's frame answer: still the frame layout" do
    Chats.config.layout = "titled_by_host"
    login_as @alice

    get "/messages/#{@conversation.id}", headers: PANE_FRAME.merge(turbo_request)
    assert_select "head title", 0

    get "/messages/#{@conversation.id}"
    assert_equal "Host · Bob", css_select("head title").sole.text, "the host's own title on a full page"
  end

  # --- the pane's own frame ------------------------------------------------------------

  test "the pane's frame gets the pane alone, in turbo-rails' frame layout: no list, no inbox stream, no host page" do
    login_as @alice

    get "/messages/#{@conversation.id}", headers: PANE_FRAME.merge(turbo_request)

    assert_response :success
    assert_select "head title", 0, "turbo-rails' frame layout, not the host's"
    assert_select "body > turbo-frame#chats_conversation", 1
    assert_select "body > *", 1, "nothing of the host's page around it"
    assert_select "section.chats-split__pane[data-title='Bob · Messages']", 1, "its title travels on the pane"
    assert_select "turbo-frame", 1
    assert_select "turbo-frame#chats_conversation > section.chats-split__pane", 1 do
      assert_select "> header.chats-thread__header h2", text: "Bob"
      assert_select "> .chats-split__thread[data-turbo-permanent] .chats-thread--pane"
    end
    assert_select "nav", 0
    assert_select ".chats-row", 0
    assert_not_includes response.body, "chats_inbox"
  end

  test "opening a conversation in the pane reads it, at once: the viewer chose it" do
    login_as @alice

    get "/messages/#{@conversation.id}", headers: PANE_FRAME.merge(turbo_request)

    assert_not @conversation.participant_for(@alice).reload.unread?
    assert_equal "false", thread_read_pending
  end

  test "the «new messages» line is drawn before the pane's read" do
    login_as @alice

    get "/messages/#{@conversation.id}", headers: PANE_FRAME.merge(turbo_request)

    assert_select ".chats-thread__unread-line", 1
  end

  test "a pane prefetched on hover reads nothing, and its thread reads once it is on screen" do
    login_as @alice

    get "/messages/#{@conversation.id}", headers: PANE_FRAME.merge(turbo_request).merge("X-Sec-Purpose" => "prefetch")

    assert @conversation.participant_for(@alice).reload.unread?
    assert_equal "true", thread_read_pending
  end

  test "another frame of the page (the search's results) gets the whole page, to find its part in, and reads nothing" do
    login_as @alice

    get "/messages/#{@conversation.id}", params: { q: "Bob" },
                                         headers: { "Turbo-Frame" => "chats_inbox_results" }.merge(turbo_request)

    assert_select "turbo-frame#chats_inbox_results li.chats-row", 1
    assert_select "section.chats-split__pane", 1
    assert @conversation.participant_for(@alice).reload.unread?
  end

  # --- when the page reads -------------------------------------------------------------

  test "the page loaded by the browser (a link from elsewhere, a reload, no JavaScript) reads the conversation" do
    login_as @alice

    get "/messages/#{@conversation.id}"

    assert_not @conversation.participant_for(@alice).reload.unread?
    assert_equal "false", thread_read_pending
  end

  test "a Turbo visit of the page, maybe the inbox's own refresh, reads nothing: its thread reads once on screen" do
    login_as @alice

    get "/messages/#{@conversation.id}", headers: turbo_request

    assert_response :success
    assert @conversation.participant_for(@alice).reload.unread?
    assert_equal "true", thread_read_pending
  end

  test "a refresh of the page never refreshes the reader's inbox again: no read, no loop" do
    login_as @alice
    clear_enqueued_jobs

    get "/messages/#{@conversation.id}", headers: turbo_request

    assert_no_enqueued_jobs(only: Chats::InboxRefreshJob)
  end

  test "a page prefetched on hover reads nothing" do
    login_as @alice

    get "/messages/#{@conversation.id}", headers: { "Sec-Purpose" => "prefetch" }

    assert @conversation.participant_for(@alice).reload.unread?
    assert_equal "true", thread_read_pending
  end

  # --- what is unchanged ----------------------------------------------------------------

  test "a conversation the viewer may not open is a 404 in the pane too" do
    block_pair!(@alice, @bob)
    login_as @alice

    get "/messages/#{@conversation.id}", headers: PANE_FRAME.merge(turbo_request)
    assert_response :not_found

    get "/messages/#{@conversation.id}"
    assert_response :not_found

    outsiders = conversation_between(@bob, @carol)
    get "/messages/#{outsiders.id}", headers: PANE_FRAME
    assert_response :not_found
  end

  test "older pages, dock windows and catch-ups answer as they always did" do
    40.times { |index| @bob.message!(@conversation, "line #{index}") }
    login_as @alice
    oldest = @conversation.messages.recent_first.limit(30).last

    get "/messages/#{@conversation.id}", params: { before: oldest.id },
                                         headers: { "Turbo-Frame" => "chats_page_#{oldest.id}" }
    assert_select "turbo-frame#chats_page_#{oldest.id}", 1
    assert_select ".chats-split", 0

    get "/messages/#{@conversation.id}", params: { window: 1 },
                                         headers: { "Turbo-Frame" => dom_id(@conversation, :window) }
    assert_select ".chats-thread--window", 1
    assert_select ".chats-split", 0
  end

  test "the dock's rows still open windows, never the pane" do
    login_as @alice

    get "/messages/dock", headers: { "Turbo-Frame" => "chats_dock_list" }

    links = css_select("a.chats-row__link")
    assert_equal 2, links.size
    assert(links.none? { |link| link["data-turbo-frame"] == "chats_conversation" })
    assert(links.all? { |link| link["data-chats-dock-conversation-id"].present? })
  end

  # --- config.inbox_layout = :stacked ------------------------------------------------

  test ":stacked keeps the separate pages: the inbox is the list alone, its rows plain links" do
    Chats.config.inbox_layout = :stacked
    login_as @alice

    get "/messages"

    assert_select ".chats.chats-inbox[data-chats-dock-hide]", 1
    assert_select ".chats-split, nav.chats-split__list, #chats_conversation", 0
    assert_select ".chats-inbox > header h1", text: "Messages"
    assert(css_select("a.chats-row__link").none? { |link| link.key?("data-turbo-frame") })
    assert_select "[data-controller~='chats--split']", 0
  end

  test ":stacked keeps the thread page, its header inside the thread, read on render" do
    Chats.config.inbox_layout = :stacked
    login_as @alice

    get "/messages/#{@conversation.id}", headers: turbo_request

    assert_select ".chats.chats-thread[data-chats-dock-hide][data-controller='chats--thread']", 1 do
      assert_select "> header.chats-thread__header h1.chats-thread__title", text: "Bob"
      assert_select "a.chats-thread__back[href='/messages/']"
    end
    assert_select ".chats-split, .chats-row", 0
    assert_not @conversation.participant_for(@alice).reload.unread?, "a Turbo visit of the thread page reads it"
  end

  test ":stacked's thread page, prefetched on hover, reads nothing and reads itself once it is on screen" do
    Chats.config.inbox_layout = :stacked
    login_as @alice

    get "/messages/#{@conversation.id}", headers: { "X-Sec-Purpose" => "prefetch" }

    assert @conversation.participant_for(@alice).reload.unread?
    assert_equal "true", thread_read_pending, "Turbo shows the prefetched page as it is: nothing else would read it"
  end

  test ":stacked answers the pane's frame with the thread page: it has no pane" do
    Chats.config.inbox_layout = :stacked
    login_as @alice

    get "/messages/#{@conversation.id}", headers: PANE_FRAME

    assert_select ".chats.chats-thread", 1
    assert_select "#chats_conversation", 0
  end

  test ":stacked's empty inbox keeps its empty state in the list" do
    Chats.config.inbox_layout = :stacked
    login_as create_user(name: "Nobody")

    with_slot_views { get "/messages" }

    assert_select ".chats-inbox .chats-empty [data-dummy-slot=inbox_empty]", 1
    assert_select ".chats-split__empty", 0
  end

  # --- an app that ejected its views -----------------------------------------------

  test "views ejected before two panes keep their own separate pages, read as before" do
    with_ejected_views("index.html.erb" => "<p id=own-inbox>mine</p>",
                       "show.html.erb" => "<p id=own-thread>mine</p>") do
      login_as @alice

      get "/messages"
      assert_select "#own-inbox"

      get "/messages/#{@conversation.id}", headers: turbo_request
      assert_select "#own-thread"
      assert_select ".chats-split", 0
      assert_not @conversation.participant_for(@alice).reload.unread?, "their thread page reads on render, as it did"
    end
  end

  test "a thread page ejected alone still renders, never the two-pane page around the gem's list" do
    with_ejected_views("show.html.erb" => "<p id=own-thread>mine</p>") do
      login_as @alice

      get "/messages/#{@conversation.id}"
      assert_select "#own-thread"

      get "/messages"
      assert_select ".chats-split", 0, "the gem's list, alone, beside no pane"
      assert(css_select("a.chats-row__link").none? { |link| link.key?("data-turbo-frame") })
    end
  end

  test "views ejected since 0.6 carry the conversation pane, and are two panes like the gem's own" do
    bundled = Chats::Engine.root.join("app/views/chats/conversations")
    files = %w[index.html.erb _conversation_pane.html.erb].to_h { |name| [name, bundled.join(name).read] }
    with_ejected_views(files) do
      login_as @alice

      get "/messages/#{@conversation.id}"
      assert_select ".chats-split section.chats-split__pane", 1
    end
  end

  private

  # The app's own copies of the engine's conversation views, as
  # `rails g chats:views` leaves them.
  def with_ejected_views(files)
    Dir.mktmpdir do |root|
      directory = File.join(root, "chats/conversations")
      FileUtils.mkdir_p(directory)
      files.each { |name, source| File.write(File.join(directory, name), source) }
      original = Chats::ApplicationController.view_paths
      Chats::ApplicationController.prepend_view_path(root)
      begin
        yield
      ensure
        Chats::ApplicationController.view_paths = original
      end
    end
  end

  # What every request Turbo makes carries (its fetches, page visits and
  # frame loads alike); a browser's own page load doesn't.
  def turbo_request
    { "X-Turbo-Request-Id" => SecureRandom.uuid }
  end

  def pane_id
    css_select(".chats-split__thread[data-turbo-permanent]").sole["id"]
  end

  def thread_read_pending
    css_select("[data-controller='chats--thread']").sole["data-chats--thread-read-pending-value"]
  end

  def with_slot_views
    original = Chats::ApplicationController.view_paths
    Chats::ApplicationController.prepend_view_path(SLOT_VIEWS)
    yield
  ensure
    Chats::ApplicationController.view_paths = original
  end
end
