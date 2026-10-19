# frozen_string_literal: true

require "test_helper"
require "capybara/rails"
require "capybara/minitest"
require "selenium-webdriver"

# A message's menu in a real, headless Chrome: the "⋯" a mouse finds beside
# the bubble, the keyboard's way into the menu and out of it, the touch screen
# that never sees the button, and a host's item (the dummy's message_menu
# slot, a Report link) living through the clone the popup makes of the
# bubble's <template>.
#
# The thread is the two-pane page's (1280px wide): its conversation sits in a
# turbo-frame, which is what a host's link must leave.
#
# Chrome is a prerequisite in CI (ENV["CI"]), as for the dock's layout tests;
# locally they skip without it. The suite's output says how many ran.
class MessageMenuBrowserTest < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [1280, 900] do |options|
    HeadlessChromeWithMouse.configure(options) # see test_helper: every class says so
  end

  include ActionView::RecordIdentifier

  @ran = 0
  @skipped = 0
  class << self
    attr_accessor :ran, :skipped
  end

  Minitest.after_run do
    ran = MessageMenuBrowserTest.ran
    skipped = MessageMenuBrowserTest.skipped
    puts "\nMessage menu tests (headless Chrome): #{ran} ran, #{skipped} skipped" \
         "#{" — Chrome unavailable" if skipped.positive?}"
  end

  setup do
    unless self.class.chrome?
      flunk "Chrome could not start, and CI requires it: #{self.class.chrome_error}" if ci?
      self.class.skipped += 1
      skip "Chrome is not available"
    end
    self.class.ran += 1
    # Capybara shares one browser between the classes, and another's device
    # metrics outlive its tests: these measure a 1280 × 900 desk.
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: 1280, height: 900, deviceScaleFactor: 1, mobile: false)

    @alice = create_user(name: "Alice")
    @bob = create_user(name: "Bob")
    @conversation = conversation_between(@alice, @bob)
    @theirs = @bob.message!(@conversation, "hola from Bob")
    @mine = @alice.message!(@conversation, "hola from Alice")
  end

  test "a mouse on a message shows ⋯ beside the bubble, on its inner edge, and it opens the menu" do
    open_thread
    theirs = "##{dom_id(@theirs)}"
    mine = "##{dom_id(@mine)}"

    assert_equal "0", trigger_style(theirs, "opacity"), "out of sight until the pointer is on the message"

    find(theirs).hover
    wait_until { trigger_style(theirs, "opacity") == "1" }
    assert_operator rect("#{theirs} [data-chats-message-menu-trigger]")["left"],
                    :>=, rect("#{theirs} .chats-message__bubble")["right"] - 1, "right of a foreign bubble"

    find(mine).hover
    wait_until { trigger_style(mine, "opacity") == "1" }
    assert_equal "0", trigger_style(theirs, "opacity"), "only on the message the pointer is on"
    assert_operator rect("#{mine} [data-chats-message-menu-trigger]")["right"],
                    :<=, rect("#{mine} .chats-message__bubble")["left"] + 1, "left of your own"

    find(theirs).hover
    find("#{theirs} [data-chats-message-menu-trigger]").click

    assert_selector ".chats-popup.chats-popup--open"
    within(".chats-popup__menu") do
      assert_selector ".chats-popup__item", text: "Copy"
      assert_selector "a.chats-popup__item", text: "Report"
    end
    assert_equal "Message options", find("#{theirs} [data-chats-message-menu-trigger]", visible: :all)["aria-label"]
  end

  test "the keyboard: one tab stop for the thread's ⋯, arrows along them, Enter opens, Escape gives the focus back" do
    open_thread
    theirs = "##{dom_id(@theirs)} [data-chats-message-menu-trigger]"
    mine = "##{dom_id(@mine)} [data-chats-message-menu-trigger]"

    page.execute_script("document.querySelector('.chats-thread__scroll').focus()")
    press :tab
    assert focused?(mine), "Tab from the history lands on the newest message's ⋯"
    assert page.evaluate_script("document.activeElement.matches(':focus-visible')")
    wait_until { page.evaluate_script("getComputedStyle(document.activeElement).opacity") == "1" }

    press :arrow_up
    assert focused?(theirs), "ArrowUp goes to the message above"
    tab_indexes = [theirs, mine].map do |button|
      page.evaluate_script("document.querySelector(#{button.to_json}).tabIndex")
    end
    assert_equal [0, -1], tab_indexes, "and the thread's one tab stop goes with it"

    press :enter
    assert_selector ".chats-popup.chats-popup--open"
    assert page.evaluate_script("document.querySelector('.chats-popup__menu').contains(document.activeElement)"),
           "the focus is on the menu's first item"

    press :escape
    assert_selector ".chats-popup", visible: :hidden
    assert focused?(theirs), "the focus is back on ⋯"

    press :tab
    assert page.evaluate_script("!!document.activeElement.closest('.chats-composer')"),
           "the next stop is the composer, not the other messages' ⋯"
  end

  test "a touch screen never shows ⋯: long-press is its way to the menu" do
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: true, maxTouchPoints: 5)
    open_thread

    assert_equal "none", trigger_style("##{dom_id(@theirs)}", "display"), "not drawn, and not a tab stop"
  ensure
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: false) if self.class.chrome?
  end

  test "a host's item lives through the clone: in a foreign message's menu, not your own's, and it leaves the frame" do
    open_thread

    find("##{dom_id(@mine)} .chats-message__bubble").right_click
    within(".chats-popup--open .chats-popup__menu") do
      assert_selector ".chats-popup__item", text: "Edit"
      assert_no_selector "[data-dummy-slot='message_menu']", visible: :all
    end
    page.driver.browser.action.send_keys(:escape).perform
    assert_selector ".chats-popup", visible: :hidden

    find("##{dom_id(@theirs)} .chats-message__bubble").right_click
    within(".chats-popup--open .chats-popup__menu") do
      assert_no_selector ".chats-popup__item", text: "Edit"
      find("a[data-dummy-slot='message_menu']", text: "Report").click
    end

    # The two-pane page's conversation is a turbo-frame; the link says _top.
    assert_selector ".dummy-home h1", text: "Dummy host"
    assert_equal "/", URI(page.current_url).path
    assert_equal "reported=#{@theirs.id}", URI(page.current_url).query
  end

  test "the focused ⋯ outlives its bubble: an edit's or a reaction's replacement gets it, a removal hands it on" do
    open_thread
    theirs = "##{dom_id(@theirs)} [data-chats-message-menu-trigger]"
    mine = "##{dom_id(@mine)} [data-chats-message-menu-trigger]"
    page.execute_script("document.querySelector('.chats-thread__scroll').focus()")
    press :tab
    press :arrow_up
    assert focused?(theirs)

    @theirs.edit!("hola, edited")
    replace_bubble(@theirs)
    assert_selector "##{dom_id(@theirs)}", text: "hola, edited"
    wait_until { focused?(theirs) }
    assert page.evaluate_script("!document.querySelector(#{theirs.to_json}).dataset.stale"), "the NEW bubble's ⋯"

    Chats::Reaction.toggle!(message: @theirs, reactor: @alice, emoji: "👍")
    replace_bubble(@theirs)
    assert_selector "##{dom_id(@theirs)} .chats-reaction"
    wait_until { focused?(theirs) }

    later = @bob.message!(@conversation, "a message arriving")
    stream("append", dom_id(@conversation, :messages), bubble_html(later))
    assert_selector "##{dom_id(later)}"
    assert focused?(theirs), "an append leaves the focus where it is"

    stream("remove", dom_id(@theirs))
    assert_no_selector "##{dom_id(@theirs)}"
    wait_until { focused?(mine) } # nothing older: the next one
  end

  test "the open menu keeps the focus: Tab cycles its controls, the arrows its items; a named modal dialog" do
    open_thread
    trigger = "##{dom_id(@theirs)} [data-chats-message-menu-trigger]"
    page.execute_script("document.querySelector(#{trigger.to_json}).focus()")
    press :enter
    assert_selector ".chats-popup.chats-popup--open"

    dialog = find(".chats-popup", visible: :all)
    assert_equal ["dialog", "true", "Message options"], [dialog["role"], dialog["aria-modal"], dialog["aria-label"]]
    assert_equal "Copy", active_text
    press :arrow_down
    assert_equal "Report", active_text
    press :end
    assert_equal "Pin", active_text
    press :arrow_down
    assert_equal "Copy", active_text, "round the end"

    press :end
    press :tab # from the last control…
    assert page.evaluate_script(<<~JS), "…to the first, never out to the page behind"
      document.activeElement === document.querySelector(".chats-popup__reaction")
    JS
    page.driver.browser.action.key_down(:shift).send_keys(:tab).key_up(:shift).perform
    assert_equal "Pin", active_text
    9.times { press :tab }
    assert page.evaluate_script("document.querySelector('.chats-popup').contains(document.activeElement)")
  end

  test "in a 336px dock window the ⋯ stays inside the window and the popup inside the screen" do
    long = "a long message that wraps across the whole dock window, to its widest " * 2
    theirs = @bob.message!(@conversation, long)
    mine = @alice.message!(@conversation, long)
    window = open_dock_window
    assert_selector "#{window} ##{dom_id(mine)}.chats-message--own"
    assert_equal 336, rect(window)["right"].round - rect(window)["left"].round

    [theirs, mine].each do |message|
      find("#{window} ##{dom_id(message)} .chats-message__bubble").hover
      trigger = rect("#{window} ##{dom_id(message)} [data-chats-message-menu-trigger]")
      scroller = rect("#{window} .chats-thread__scroll")
      assert_operator trigger["left"], :>=, scroller["left"], "inside the window's left edge"
      assert_operator trigger["right"], :<=, scroller["right"], "inside the window's right edge"
    end
    scroller = "document.querySelector(#{"#{window} .chats-thread__scroll".to_json})"
    assert_equal 0, page.evaluate_script("#{scroller}.scrollWidth - #{scroller}.clientWidth"), "no sideways scroll"

    find("#{window} ##{dom_id(theirs)} .chats-message__bubble").hover
    find("#{window} ##{dom_id(theirs)} [data-chats-message-menu-trigger]").click
    assert_selector "#{window} .chats-popup.chats-popup--open"
    sleep 0.4 # the morph
    viewport = page.evaluate_script("({ width: innerWidth, height: innerHeight })")
    %w[.chats-popup__slot--reactions .chats-popup__slot--bubble .chats-popup__slot--menu].each do |slot|
      box = rect("#{window} #{slot}")
      assert_operator box["left"], :>=, 0, "#{slot} on the screen"
      assert_operator box["top"], :>=, 0, "#{slot} on the screen"
      assert_operator box["right"], :<=, viewport["width"], "#{slot} on the screen"
      assert_operator box["bottom"], :<=, viewport["height"], "#{slot} on the screen"
    end
  end

  test "a cloned button_to posts with forgery protection on, from a page's bubble and from a broadcast's" do
    open_thread(visit_thread: false)
    ActionController::Base.allow_forgery_protection = true
    visit "/messages/#{@conversation.id}"
    assert_selector "##{dom_id(@mine)}.chats-message--own"

    find("##{dom_id(@theirs)} .chats-message__bubble").right_click
    within(".chats-popup--open .chats-popup__menu") do
      assert_selector "form[data-dummy-slot='message_menu_form'] input[name='authenticity_token']", visible: :all
      click_on "Pin"
    end
    assert_selector ".dummy-home h1", text: "Dummy host"
    assert_equal "pinned=#{@theirs.id}", URI(page.current_url).query

    # A live bubble: rendered once for everybody, outside any viewer's session.
    visit "/messages/#{@conversation.id}"
    assert_selector "##{dom_id(@mine)}.chats-message--own"
    live = @bob.message!(@conversation, "live one")
    stream("append", dom_id(@conversation, :messages), bubble_html(live))
    find("##{dom_id(live)} .chats-message__bubble").right_click
    within(".chats-popup--open .chats-popup__menu") { click_on "Pin" }
    assert_selector ".dummy-home h1", text: "Dummy host"
    assert_equal "pinned=#{live.id}", URI(page.current_url).query
  ensure
    ActionController::Base.allow_forgery_protection = false
  end

  test "a dock window closed with its menu open takes the menu's keys with it: Tab moves on the page again" do
    window = open_dock_window
    find("#{window} ##{dom_id(@theirs)} .chats-message__bubble").hover
    find("#{window} ##{dom_id(@theirs)} [data-chats-message-menu-trigger]").click
    assert_selector "#{window} .chats-popup.chats-popup--open"

    # The dock's own way out (dropWindow), under the open menu.
    page.execute_script("document.querySelector(arguments[0]).click()", "#{window} .chats-window__close")
    assert_no_selector window

    page.execute_script("window.__before = document.activeElement")
    press :tab
    moved = "document.activeElement !== window.__before && document.activeElement !== document.body"
    assert page.evaluate_script(moved),
           "Tab moved the focus: no listener left to swallow it"
  end

  test "a cloned form carries the page's token: a native submit, Turbo off around the thread, passes" do
    open_thread(visit_thread: false)
    ActionController::Base.allow_forgery_protection = true
    visit "/messages/#{@conversation.id}"
    assert_selector "##{dom_id(@mine)}.chats-message--own"
    live = @bob.message!(@conversation, "live one")
    stream("append", dom_id(@conversation, :messages), bubble_html(live)) # rendered outside any session
    page.execute_script("document.querySelector('.chats-thread').dataset.turbo = 'false'")

    page.execute_script("window.__samePage = true") # a Turbo visit keeps it, a native submit's page load does not
    find("##{dom_id(live)} .chats-message__bubble").right_click
    within(".chats-popup--open .chats-popup__menu") do
      token = find("form[data-dummy-slot='message_menu_form'] input[name='authenticity_token']", visible: :all).value
      assert_equal page.evaluate_script("document.querySelector('meta[name=csrf-token]').content"), token
      click_on "Pin"
    end
    assert_selector ".dummy-home h1", text: "Dummy host"
    assert_equal "pinned=#{live.id}", URI(page.current_url).query
    assert_nil page.evaluate_script("window.__samePage"), "a native submit, not Turbo's"
  ensure
    ActionController::Base.allow_forgery_protection = false
  end

  # Starting a browser once tells whether this machine can run these.
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

  def ci?
    %w[1 true yes].include?(ENV["CI"].to_s.downcase)
  end

  def open_thread(visit_thread: true)
    visit "/"
    page.evaluate_async_script(<<~JS, @alice.to_global_id.to_s)
      const done = arguments[arguments.length - 1];
      localStorage.clear();
      fetch("/test_login", { method: "POST", body: new URLSearchParams({ messager_gid: arguments[0] }) }).then(() => done());
    JS
    return unless visit_thread

    visit "/messages/#{@conversation.id}"
    assert_selector "##{dom_id(@mine)}.chats-message--own" # the thread controller has classified the bubbles
  end

  # The conversation with Bob in a dock window on a host page, its bubbles classified.
  def open_dock_window
    open_thread(visit_thread: false)
    visit "/"
    find(".chats-dock__bar").click
    find("#chats_dock_list a", text: "Bob").click
    window = "turbo-frame.chats-window[data-conversation-id='#{@conversation.id}']"
    using_wait_time(10) { assert_selector "#{window} ##{dom_id(@mine)}.chats-message--own" }
    window
  end

  # What a broadcast hands the page: the bubble rendered once, by the host's renderer.
  def bubble_html(message)
    ApplicationController.render(partial: "chats/messages/message", locals: { message: message.reload })
  end

  def replace_bubble(message)
    page.execute_script("document.getElementById(arguments[0]).querySelector('[data-chats-message-menu-trigger]')" \
                        ".dataset.stale = 'old'", dom_id(message))
    stream("replace", dom_id(message), bubble_html(message))
  end

  def stream(action, target, html = "")
    markup = %(<turbo-stream action="#{action}" target="#{target}"><template>#{html}</template></turbo-stream>)
    page.execute_script("Turbo.renderStreamMessage(arguments[0])", markup)
  end

  def active_text
    page.evaluate_script("document.activeElement.textContent.trim()")
  end

  def press(key)
    page.driver.browser.action.send_keys(key).perform
  end

  def focused?(selector)
    page.evaluate_script("document.activeElement === document.querySelector(#{selector.to_json})")
  end

  def trigger_style(message, property)
    page.evaluate_script(<<~JS)
      getComputedStyle(document.querySelector(#{"#{message} [data-chats-message-menu-trigger]".to_json})).#{property}
    JS
  end

  def rect(selector)
    page.evaluate_script(<<~JS)
      (() => { const r = document.querySelector(#{selector.to_json}).getBoundingClientRect();
               return { left: r.left, right: r.right, top: r.top, bottom: r.bottom } })()
    JS
  end

  def wait_until(seconds = Capybara.default_max_wait_time)
    Timeout.timeout(seconds) { sleep 0.05 until yield }
  end
end
