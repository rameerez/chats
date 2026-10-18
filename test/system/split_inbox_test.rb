# frozen_string_literal: true

require "test_helper"
require "capybara/rails"
require "capybara/minitest"
require "selenium-webdriver"

# The two-pane messaging page (`config.inbox_layout = :split`) in a real,
# headless Chrome: what the browser renders at each width, what a row click
# does there, and what the inbox's live refresh leaves alone.
#
# The cable is the test adapter: nothing arrives live. A broadcast is what
# the page gets from Turbo when one does arrive, so the tests hand the page
# exactly that (the `refresh` stream Chats::InboxRefreshJob broadcasts).
#
# Chrome is a prerequisite in CI (ENV["CI"]), as for the dock's layout tests;
# locally they skip without it. The suite's output says how many ran.
class SplitInboxBrowserTest < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [1280, 900]

  @ran = 0
  @skipped = 0
  class << self
    attr_accessor :ran, :skipped
  end

  Minitest.after_run do
    ran = SplitInboxBrowserTest.ran
    skipped = SplitInboxBrowserTest.skipped
    puts "\nTwo-pane inbox tests (headless Chrome): #{ran} ran, #{skipped} skipped" \
         "#{" — Chrome unavailable" if skipped.positive?}"
  end

  setup do
    unless self.class.chrome?
      flunk "Chrome could not start, and CI requires it: #{self.class.chrome_error}" if ci?
      self.class.skipped += 1
      skip "Chrome is not available"
    end
    self.class.ran += 1

    @alice = create_user(name: "Alice")
    @bob = create_user(name: "Bob")
    @carol = create_user(name: "Carol")
    @with_bob = conversation_between(@alice, @bob)
    40.times { |index| @bob.message!(@with_bob, "line #{index} from Bob") }
    @with_carol = conversation_between(@alice, @carol)
    @carol.message!(@with_carol, "hola from Carol")
  end

  # --- wide ------------------------------------------------------------------------

  test "at 1280px both panes fill the screen side by side, the list 320px, and nothing scrolls sideways" do
    sign_in_at(1280)
    visit "/messages"

    assert_selector ".chats-split__empty", text: "Select a conversation"
    list = rect(".chats-split__list")
    pane = rect(".chats-split__conversation")
    assert_equal 320, list["width"].round
    assert_operator pane["left"], :>=, list["right"] - 1
    assert_equal 900, list["height"].round
    assert_equal 900, pane["height"].round
    assert_no_sideways_scroll
    assert_equal true, page.evaluate_script("document.getElementById('chats_conversation').disabled === false"),
                 "a wide screen opens rows in the pane"
  end

  test "a row opens its conversation in the pane: no visit, the address bar moves, the row is current, it's read" do
    sign_in_at(1280)
    visit "/messages"
    assert_selector "#chats_conversation:not([disabled])"
    mark_page

    find(".chats-split__list a", text: "Bob").click

    assert_selector ".chats-split__pane .chats-thread__title", text: "Bob"
    assert_selector ".chats-thread--pane [data-chats--thread-target='message']", text: "line 39 from Bob"
    assert_equal "/messages/#{@with_bob.id}", URI(page.current_url).path
    assert_equal true, page.evaluate_script("document.body.__samePage === true"), "the pane loaded without a page visit"
    assert_selector "li.chats-row--current a[aria-current=page]", text: "Bob"
    assert_selector "a[aria-current]", count: 1
    assert_selector ".chats-split__list", visible: true

    wait_until { !@with_bob.participant_for(@alice).reload.unread? }

    # The read refreshes the reader's inbox, which agrees.
    broadcast_refresh
    assert_selector "li.chats-row:not(.chats-row--unread)", text: "Bob"
    assert_no_selector "li.chats-row--current .chats-badge"
    assert_selector "li.chats-row--current", text: "Bob"
  end

  test "the open row's unread count goes the moment the pane reads it, not when the list next refreshes" do
    sign_in_at(1280)
    visit "/messages"
    assert_selector "#chats_conversation:not([disabled])"
    assert_selector "li.chats-row.chats-row--unread", text: "Bob" do
      assert_selector ".chats-badge", text: "40"
    end

    find(".chats-split__list a", text: "Bob").click # the server reads it as it renders the pane

    # No refresh came (the cable is a test one): the page cleared it itself.
    assert_selector "li.chats-row--current:not(.chats-row--unread)", text: "Bob"
    assert_no_selector "li.chats-row--current .chats-badge"
    assert_selector "li.chats-row.chats-row--unread .chats-badge", text: "1" # Carol's is not this one
  end

  test "a pane rendered unread clears its row once its thread reads it on screen" do
    sign_in_at(1280)
    visit "/messages"
    assert_selector "#chats_conversation:not([disabled])"

    page.execute_script("Turbo.visit('/messages/#{@with_bob.id}')") # a Turbo visit: the server doesn't read
    assert_selector ".chats-split__pane[data-read='false'] .chats-thread__title", text: "Bob"

    assert_selector "li.chats-row--current:not(.chats-row--unread)", text: "Bob" # the thread read it, ~0.7s in
    assert_no_selector "li.chats-row--current .chats-badge"
    wait_until { !@with_bob.participant_for(@alice).reload.unread? }
  end

  test "a touch screen's tapped row keeps no hover tint; a mouse's still gets one" do
    sign_in_at(1280)
    visit "/messages/#{@with_bob.id}"
    row = ".chats-split__list li:not(.chats-row--current) a.chats-row__link"
    find(row).hover
    hovered = page.evaluate_script("getComputedStyle(document.querySelector(#{row.to_json})).backgroundColor")
    assert_not_equal "rgba(0, 0, 0, 0)", hovered, "a mouse hovering a row tints it"

    # A touch screen: Chrome's touch emulation answers (hover: none), as a phone or a tablet does.
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: true, maxTouchPoints: 5)
    find(row).hover # what a tap leaves behind
    assert_equal "rgba(0, 0, 0, 0)",
                 page.evaluate_script("getComputedStyle(document.querySelector(#{row.to_json})).backgroundColor")
  ensure
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: false) if self.class.chrome?
  end

  test "the tab takes the title of the conversation a row opens: Turbo leaves <head> alone on a frame visit" do
    sign_in_at(1280)
    visit "/messages/#{@with_carol.id}"
    assert_equal "Carol · Dummy", page.title

    find(".chats-split__list a", text: "Bob").click

    assert_selector ".chats-split__pane .chats-thread__title", text: "Bob"
    wait_until { page.title == "Bob · Dummy" }
    assert_equal "Bob · Dummy", page.title

    page.go_back # a restore re-fetches the page (no-cache): its own title
    assert_selector ".chats-split__pane .chats-thread__title", text: "Carol"
    wait_until { page.title == "Carol · Dummy" }
  end

  test "a row opened from a stack keeps the stack: the address bar carries it, and a refresh keeps the list filtered" do
    desk = create_desk(name: "Soporte")
    first, = Array.new(2) do |index|
      ticket = @alice.chat_with(desk, about: create_listing(title: "Listing #{index}"))
      desk.message!(ticket, "ticket #{index}")
      ticket
    end
    sign_in_at(1280)
    visit "/messages"
    find("li.chats-row--group a").click # a deeper stack: the stack list, a page
    assert_selector ".chats-inbox__filter", text: "Soporte"
    assert_selector "#chats_conversation:not([disabled])"
    assert_selector ".chats-split__list li.chats-row", count: 2

    find(".chats-split__list a", text: "ticket 0").click
    assert_selector ".chats-split__pane[data-conversation-id='#{first.id}']"
    url = URI(page.current_url)
    assert_equal "/messages/#{first.id}", url.path
    assert_includes url.query.to_s, "with=", "the address bar keeps the stack"

    @bob.message!(@with_bob, "a message elsewhere") # what the refresh is about
    broadcast_refresh
    assert_selector ".chats-split__pane[data-conversation-id='#{first.id}']"
    sleep 0.5 # the morph has landed (the list would hold Bob's row if it had gone back to the inbox)
    assert_selector ".chats-inbox__filter", text: "Soporte"
    assert_selector ".chats-split__list li.chats-row", count: 2
    assert_no_selector ".chats-split__list li.chats-row", text: "Bob"
    assert_selector "li.chats-row--current", text: "ticket 0"
  end

  test "a row click takes the viewer into the conversation: the composer has the focus, inside the labelled pane" do
    sign_in_at(1280)
    visit "/messages"
    assert_selector "#chats_conversation:not([disabled])"

    find(".chats-split__list a", text: "Carol").click

    assert_selector ".chats-split__pane .chats-thread__title", text: "Carol"
    wait_until { page.evaluate_script("document.activeElement?.matches('.chats-split__pane .chats-composer__input')") }
    label = page.evaluate_script(<<~JS)
      document.getElementById(document.activeElement.closest("section").getAttribute("aria-labelledby")).textContent.trim()
    JS
    assert_equal "Carol", label, "a screen reader entering the pane hears whose conversation it is"
  end

  test "under a host's own header, the page fits what is left of the screen: no page scroll, the composer in view" do
    Chats.config.layout = "with_header"
    sign_in_at(1280)

    visit "/messages/#{@with_bob.id}"
    assert_selector ".chats-thread--pane .chats-composer__input"
    assert_fits_under_the_header

    resize(390, mobile: true)
    visit "/messages/#{@with_bob.id}"
    assert_selector ".chats-split__pane .chats-thread__back", visible: true
    assert_fits_under_the_header

    visit "/messages" # the list alone
    assert_selector ".chats-split__list li.chats-row", count: 2
    assert_fits_under_the_header(composer: false)
  end

  test "under a host's own header, a phone's empty inbox fits what is left of the screen too" do
    Chats.config.layout = "with_header"
    sign_in_at(390, mobile: true, viewer: create_user(name: "Nobody"))

    visit "/messages"

    assert_selector ".chats-split__empty--inbox", visible: true
    assert_fits_under_the_header(composer: false)
    assert_equal page.evaluate_script("window.innerHeight") - 56, rect(".chats-split")["height"].round,
                 "the list page still fills the rest of the screen"
  end

  test "a refresh of the list leaves the open conversation alone: draft, scroll, focus, the thread itself" do
    sign_in_at(1280)
    visit "/messages/#{@with_bob.id}"
    assert_selector ".chats-thread--pane [data-chats--thread-target='message']", text: "line 39 from Bob"
    composer = find(".chats-thread--pane .chats-composer__input")
    composer.send_keys("half a thought")
    page.execute_script(<<~JS)
      const scroller = document.querySelector(".chats-thread--pane .chats-thread__scroll")
      scroller.scrollTop = 120
      document.querySelector(".chats-thread--pane").__same = true
    JS
    scrolled = page.evaluate_script("document.querySelector('.chats-thread--pane .chats-thread__scroll').scrollTop")
    composer.click

    @carol.message!(@with_carol, "a new one from Carol")
    broadcast_refresh

    assert_selector "li.chats-row", text: "a new one from Carol" # the list re-rendered…
    assert_selector "li.chats-row.chats-row--unread", text: "Carol"
    assert_equal "half a thought", find(".chats-thread--pane .chats-composer__input").value # …the pane didn't
    assert_equal scrolled,
                 page.evaluate_script("document.querySelector('.chats-thread--pane .chats-thread__scroll').scrollTop")
    assert_equal true, page.evaluate_script("document.querySelector('.chats-thread--pane').__same === true")
    assert_equal true, page.evaluate_script("document.activeElement?.classList.contains('chats-composer__input')")
    assert_selector "turbo-cable-stream-source[connected]", minimum: 2, visible: :all # the inbox's and the thread's
    assert_equal false, page.evaluate_script("document.getElementById('chats_conversation').disabled"),
                 "the refresh's markup says disabled; the wide screen keeps it enabled"
  end

  test "a refresh after a row opened the pane morphs the conversation's page, and keeps the pane" do
    sign_in_at(1280)
    visit "/messages"
    find(".chats-split__list a", text: "Bob").click
    assert_selector ".chats-thread--pane [data-chats--thread-target='message']", text: "line 39 from Bob"
    find(".chats-thread--pane .chats-composer__input").send_keys("typed after the click")
    page.execute_script("document.querySelector('.chats-thread--pane').__same = true")

    @carol.message!(@with_carol, "while Bob was open")
    broadcast_refresh

    assert_selector "li.chats-row", text: "while Bob was open"
    assert_equal true, page.evaluate_script("document.querySelector('.chats-thread--pane').__same === true")
    assert_equal "typed after the click", find(".chats-thread--pane .chats-composer__input").value
    assert_selector "li.chats-row--current", text: "Bob"
  end

  test "a page that may have missed broadcasts catches up once per surface: one page refresh, one thread catch-up" do
    sign_in_at(1280)
    visit "/messages/#{@with_bob.id}"
    assert_selector ".chats-thread--pane [data-chats--thread-target='message']", text: "line 39 from Bob"
    sleep 0.5 # past the page's own load
    page.execute_script("performance.clearResourceTimings(); performance.setResourceTimingBufferSize(1000)")

    page.execute_script("window.dispatchEvent(new Event('online'))")
    sleep 1.5

    requests = page.evaluate_script("performance.getEntriesByType('resource').map((entry) => entry.name)")
                   .map { |url| URI(url) }
    page_refreshes = requests.count { |url| url.path == "/messages/#{@with_bob.id}" }
    thread_catch_ups = requests.count { |url| url.path == "/messages/#{@with_bob.id}/refresh" }
    assert_equal 1, page_refreshes, "the list's: #{requests.map(&:to_s)}"
    assert_equal 1, thread_catch_ups, "the pane's: #{requests.map(&:to_s)}"
  end

  test "Tab goes from the list into the open conversation, its composer reachable" do
    sign_in_at(1280)
    visit "/messages/#{@with_bob.id}"
    assert_selector ".chats-thread--pane .chats-composer__input"
    page.execute_script("document.querySelectorAll('.chats-split__list a.chats-row__link')[1].focus()")

    reached = nil
    12.times do
      page.driver.browser.action.send_keys(:tab).perform
      where = page.evaluate_script(<<~JS)
        document.activeElement.closest(".chats-split__pane") ? (document.activeElement.matches(".chats-composer__input") ? "composer" : "pane") : "elsewhere"
      JS
      assert_not_equal "elsewhere", where, "after the list comes the pane" if reached.nil?
      reached = where
      break if where == "composer"
    end
    assert_equal "composer", reached
  end

  test "a dock shown everywhere keeps no window for the conversation the pane opens" do
    sign_in_at(1280)
    page.execute_script("document.cookie = 'dock_everywhere=1; path=/'")
    visit "/"
    assert_selector ".chats-dock[data-mode]"
    find(".chats-dock__bar").click
    find("#chats_dock_list a", text: "Bob").click
    using_wait_time(10) do
      assert_selector "turbo-frame.chats-window[data-conversation-id='#{@with_bob.id}'] .chats-thread"
    end

    page.execute_script("Turbo.visit('/messages')")
    assert_selector "#chats_conversation:not([disabled])"
    assert_selector "turbo-frame.chats-window[data-conversation-id='#{@with_bob.id}']" # the page doesn't show it yet
    find(".chats-split__list a", text: "Bob").click

    assert_selector ".chats-split__pane .chats-thread__title", text: "Bob"
    assert_no_selector "turbo-frame.chats-window[data-conversation-id='#{@with_bob.id}']", visible: :all
    assert_equal 1, page.evaluate_script("document.querySelectorAll('[id=\"#{dom_id(@with_bob, :messages)}\"]').length")
  end

  test "no sideways scroll at 700, 1024 and 1440 with a conversation open" do
    @bob.update!(name: "Bob With A Remarkably Long Display Name That Never Ends Anywhere")
    @bob.message!(@with_bob, "a" * 400)
    sign_in_at(1280)

    [700, 1024, 1440].each do |width|
      resize(width)
      visit "/messages/#{@with_bob.id}"
      assert_selector ".chats-thread--pane [data-chats--thread-target='message']", text: "a" * 40
      assert_selector ".chats-split__list", visible: true
      assert_no_sideways_scroll(width)
      list = rect(".chats-split__list")
      pane = rect(".chats-split__conversation")
      assert_operator pane["right"], :<=, width + 0.5, "at #{width}px"
      assert_operator list["width"].round, :==, 320, "at #{width}px"
      composer = rect(".chats-thread--pane .chats-composer")
      assert_operator composer["bottom"].round, :<=, rect(".chats-split")["bottom"].round,
                      "the composer sits at the bottom of the page, not under it, at #{width}px"
    end
  end

  # --- narrow ----------------------------------------------------------------------

  test "at 390px the inbox is the list alone, a row opens the thread page, and back returns to the list" do
    sign_in_at(390, mobile: true)
    visit "/messages"

    assert_selector ".chats-split__list", visible: true
    assert_no_selector ".chats-split__conversation", visible: true
    assert_equal true, page.evaluate_script("document.getElementById('chats_conversation').disabled"),
                 "the frame stays disabled: a row opens the page"
    assert_no_sideways_scroll(390)
    mark_page

    find(".chats-split__list a", text: "Bob").click

    assert_selector ".chats-split__pane .chats-thread__back", visible: true
    assert_equal "/messages/#{@with_bob.id}", URI(page.current_url).path
    assert_equal false, page.evaluate_script("document.body.__samePage === true"), "a page visit, not the frame"
    assert_no_selector ".chats-split__list", visible: true
    pane = rect(".chats-split__conversation")
    shell = rect(".chats-split")
    assert_equal shell["width"].round, pane["width"].round,
                 "the thread takes the whole column (the host's body margin aside)"
    assert_equal 900, pane["height"].round, "as tall as the screen"
    assert_operator rect(".chats-thread--pane .chats-composer")["bottom"].round, :<=, shell["bottom"].round
    assert_no_sideways_scroll(390)

    page.go_back

    assert_selector ".chats-split__list", visible: true
    assert_equal "/messages", URI(page.current_url).path.chomp("/")
    assert_no_selector ".chats-split__pane"
  end

  test "at 390px the back link returns to the list" do
    sign_in_at(390, mobile: true)
    visit "/messages/#{@with_bob.id}"

    find(".chats-thread__back").click

    assert_selector ".chats-split__list li.chats-row", count: 2
    assert_no_selector ".chats-split__pane"
  end

  test "at 390px an empty inbox shows its empty state under the list's title" do
    sign_in_at(390, mobile: true, viewer: create_user(name: "Nobody"))
    visit "/messages"

    assert_selector ".chats-split__empty--inbox", text: "No conversations yet", visible: true
    assert_no_selector ".chats-split__empty", text: "Select a conversation"
  end

  def self.chrome?
    return @chrome if defined?(@chrome)

    options = Selenium::WebDriver::Chrome::Options.new(args: ["--headless=new"])
    Selenium::WebDriver.for(:chrome, options: options).quit
    @chrome = true
  rescue StandardError => e
    @chrome_error = "#{e.class}: #{e.message.lines.first}"
    @chrome = false
  end

  class << self
    attr_reader :chrome_error
  end

  private

  include ActionView::RecordIdentifier

  def ci?
    %w[1 true yes].include?(ENV["CI"].to_s.downcase)
  end

  def sign_in_at(width, mobile: false, viewer: @alice)
    resize(width, mobile: mobile)
    visit "/"
    page.evaluate_async_script(<<~JS, viewer.to_global_id.to_s)
      const done = arguments[arguments.length - 1];
      localStorage.clear();
      fetch("/test_login", { method: "POST", body: new URLSearchParams({ messager_gid: arguments[0] }) }).then(() => done());
    JS
  end

  def resize(width, height: 900, mobile: false)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: width, height: height, deviceScaleFactor: 1, mobile: mobile)
    page.execute_script("window.dispatchEvent(new Event('resize'))") if page.current_url.start_with?("http")
    sleep 0.2
  end

  # Turbo Drive replaces <body> on a page visit; a frame load keeps it.
  def mark_page
    page.execute_script("document.body.__samePage = true")
  end

  # What Turbo renders when the inbox's refresh broadcast arrives
  # (Chats::Broadcasts.refresh_inbox_of, Chats::InboxRefreshJob).
  def broadcast_refresh
    page.execute_script(<<~JS)
      Turbo.renderStreamMessage('<turbo-stream action="refresh" method="morph" scroll="preserve"></turbo-stream>')
    JS
  end

  def rect(selector)
    page.evaluate_script(<<~JS)
      (() => { const r = document.querySelector(#{selector.to_json}).getBoundingClientRect();
               return { left: r.left, right: r.right, top: r.top, bottom: r.bottom, width: r.width, height: r.height } })()
    JS
  end

  def assert_fits_under_the_header(composer: true)
    viewport = page.evaluate_script("window.innerHeight")
    assert_equal 56, rect(".chats-split")["top"].round, "the page starts under the header"
    assert_operator page.evaluate_script("document.documentElement.scrollHeight"), :<=, viewport,
                    "the page doesn't scroll"
    return unless composer

    assert_operator rect(".chats-thread--pane .chats-composer")["bottom"].round, :<=, viewport,
                    "the composer is in view"
  end

  def assert_no_sideways_scroll(width = 1280)
    scroll_width = page.evaluate_script("document.documentElement.scrollWidth")
    assert_operator scroll_width, :<=, width, "the page scrolls sideways at #{width}px (#{scroll_width}px wide)"
  end

  def wait_until(seconds = Capybara.default_max_wait_time)
    Timeout.timeout(seconds) { sleep 0.05 until yield }
  end
end
