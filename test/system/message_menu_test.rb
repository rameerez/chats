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

  def open_thread
    visit "/"
    page.evaluate_async_script(<<~JS, @alice.to_global_id.to_s)
      const done = arguments[arguments.length - 1];
      localStorage.clear();
      fetch("/test_login", { method: "POST", body: new URLSearchParams({ messager_gid: arguments[0] }) }).then(() => done());
    JS
    visit "/messages/#{@conversation.id}"
    assert_selector "##{dom_id(@mine)}.chats-message--own" # the thread controller has classified the bubbles
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
