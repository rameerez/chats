# frozen_string_literal: true

require "test_helper"
require "capybara/rails"
require "capybara/minitest"
require "selenium-webdriver"

# The tray's layout promises (0.7.0), measured in a real headless Chrome
# against the dummy host, which puts a host launcher of its own ("Need
# help?", layouts/_help_item) in the dock's tray when the `dock_tray` cookie
# is set:
#
#   * on a desk, the tab sits on the bottom edge beside the bar, and nothing
#     ever overlaps: not when it opens (the windows give it room), not with
#     the panel (one menu open at a time);
#   * on a phone, its round button sits above the dock's, its sheet fills
#     the screen and makes the page inert, and Escape gives it all back;
#   * signed out, the same tab stands alone in the corner.
#
# Chrome is a prerequisite in CI, as for the dock's layout tests.
class TrayLayoutTest < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [1800, 1000] do |options|
    HeadlessChromeWithMouse.configure(options) # see test_helper: every class says so
  end

  @ran = 0
  @skipped = 0
  class << self
    attr_accessor :ran, :skipped
  end

  Minitest.after_run do
    puts "\nTray layout tests (headless Chrome): #{TrayLayoutTest.ran} ran, #{TrayLayoutTest.skipped} skipped" \
         "#{" — Chrome unavailable" if TrayLayoutTest.skipped.positive?}"
  end

  setup do
    unless self.class.chrome?
      flunk "Chrome could not start, and CI requires it for the tray's layout tests: #{self.class.chrome_error}" if ci?
      self.class.skipped += 1
      skip "Chrome is not available"
    end
    self.class.ran += 1

    @alice = create_user(name: "Alice")
    @people = %w[Bruno Carla].map do |name|
      person = create_user(name: name)
      person.message!(@alice, "hola from #{name}")
      person
    end
  end

  test "on a desk the tab sits on the bottom edge beside the bar, and opening it closes the panel" do
    sign_in_at(1280)

    tab = rect(".chats-tray__item")
    bar = rect(".chats-dock__panel")
    assert_in_delta bar["bottom"], tab["bottom"], 1, "flush with the bar, on the bottom edge"
    assert_in_delta bar["height"], tab["height"], 1, "as tall as the bar"
    assert_operator tab["right"], :<=, bar["left"], "left of the bar, never over it"
    assert_operator tab["width"], :<, 200, "a tab, not a panel"
    assert_selector "#dummy_help_badge", text: "2"

    find(".chats-dock__bar").click
    assert_selector ".chats-dock__panel[open]"
    find(".chats-tray__launcher").click
    settle

    assert_selector ".chats-tray__item[open] .dummy-help"
    assert_no_selector ".chats-dock__panel[open]", wait: 2
    item = rect(".chats-tray__item")
    assert_in_delta 336, item["width"], 1, "a window's width"
    assert_operator item["right"], :<=, rect(".chats-dock__panel")["left"]
    assert_operator item["top"], :>=, 0

    find(".chats-dock__bar").click
    assert_selector ".chats-dock__panel[open]"
    assert_no_selector ".chats-tray__item[open]", wait: 2
  end

  test "an item opening takes its room from the windows: nothing overlaps" do
    sign_in_at(1280)
    find(".chats-dock__bar").click
    open_row("Bruno")
    open_row("Carla")
    assert_selector ".chats-window", count: 2
    assert_nothing_overlaps

    find(".chats-tray__launcher").click
    assert_selector ".chats-tray__item[open]"
    sleep 0.3 # the tray's width is observed, then the row reflows in a frame

    assert_selector ".chats-window", count: 1 # two windows and an open item don't fit at 1280
    assert_nothing_overlaps
  end

  test "Escape closes the item and gives the focus back to its tab" do
    sign_in_at(1280)
    find(".chats-tray__launcher").click
    find("#dummy_help_question").click

    find("#dummy_help_question").send_keys(:escape)

    assert_no_selector ".chats-tray__item[open]"
    assert page.evaluate_script("document.activeElement.matches('.chats-tray__launcher')")
  end

  test "a reload on a desk brings the open item back" do
    sign_in_at(1280)
    find(".chats-tray__launcher").click
    assert_selector ".chats-tray__item[open]"

    visit "/"

    assert_selector ".chats-tray__item[open] .dummy-help"
  end

  test "on a phone the round button sits above the dock's, and its sheet fills the screen, modal" do
    sign_in_at(390, height: 844, mobile: true)

    help = rect(".chats-tray__item")
    messages = rect(".chats-dock__panel")
    assert_in_delta 48, help["width"], 1
    assert_in_delta 56, messages["width"], 1
    assert_operator help["bottom"], :<=, messages["top"] - 8, "stacked above the dock's button"
    assert_in_delta messages["right"], help["right"], 1, "on the same edge"

    find(".chats-tray__launcher").click
    settle

    sheet = rect(".chats-tray__item")
    assert_equal [0, 0, 390, 844], [sheet["left"], sheet["top"], sheet["width"], sheet["height"]].map(&:round),
                 "the whole screen"
    assert_no_selector ".chats-dock__panel", visible: true # nothing floats over the sheet
    # inert reflects to its attribute: Capybara waits for it (the item's toggle event is async).
    assert_selector ".dummy-home[inert]", visible: :all # the page behind it is inert
    assert_selector "html.chats-dock-sheet-open", visible: :all # and doesn't scroll

    find(".chats-tray__close-glyph").click
    assert_no_selector ".chats-tray__item[open]"
    assert_no_selector ".dummy-home[inert]", visible: :all # live again once it closes
    assert_no_selector "html.chats-dock-sheet-open", visible: :all
  end

  test "on a phone, launcher: false takes the tray's round buttons away with the dock's" do
    sign_in_at(390, height: 844, mobile: true, query: "?dock_launcher=0")

    assert_no_selector ".chats-tray__item", visible: true
    assert_no_selector ".chats-dock__panel", visible: true
  end

  test "a Turbo visit to a page that renders other items: the carried tray follows it, by key" do
    sign_in_at(1280)
    find(".chats-tray__launcher").click
    assert_selector ".chats-tray__item[open]"

    page.execute_script("Turbo.visit('/')") # the same item: carried as it is, still open
    assert_selector ".chats-tray__item[open] .dummy-help"

    page.driver.browser.manage.delete_cookie("dock_tray")
    page.execute_script("Turbo.visit('/')") # a page without it: the permanent dock stays, the item goes
    assert_selector ".chats-dock .chats-dock__bar"
    assert_no_selector ".chats-tray__item", visible: :all
  end

  test "a visit to a page with other words and badge for the same item: both follow, an open frame survives" do
    sign_in_at(1280)
    find(".chats-tray__launcher").click
    find("#dummy_help_question").send_keys("my order never came")
    page.execute_script("window.__frame = document.getElementById('dummy_help_frame')")

    set_cookie("dock_tray", "5")
    set_cookie("dock_tray_label", "Ask us")
    page.execute_script("Turbo.visit('/')")

    assert_selector "#dummy_help_badge", text: "5"
    assert_selector ".chats-tray__label", text: "Ask us", visible: :all
    assert_selector ".chats-tray__item[open]"
    assert page.evaluate_script("document.getElementById('dummy_help_frame') === window.__frame"),
           "the open frame is the same live element"
    assert_equal "my order never came", find("#dummy_help_question").value

    find(".chats-tray__launcher").click # closed: the next visit renders its panel afresh
    assert_no_selector ".chats-tray__item[open]"
    set_cookie("dock_tray", "1")
    page.execute_script("Turbo.visit('/')")
    assert_selector "#dummy_help_badge", text: "1", visible: :all
    assert page.evaluate_script("document.getElementById('dummy_help_frame') !== window.__frame")
  end

  test "an open frame stays only while the new page renders the same one: same id and src" do
    sign_in_at(1280)
    set_cookie("dock_tray_frame", "a")
    page.execute_script("Turbo.visit('/')")
    find(".chats-tray__launcher").click
    assert_selector "#dummy_help_frame .dummy-thread", text: "Thread a"
    find("#dummy_help_reply").send_keys("half a reply")
    page.execute_script("window.__frame = document.getElementById('dummy_help_frame')")

    page.execute_script("Turbo.visit('/')") # the same frame: the element and what was typed survive
    assert_selector ".chats-tray__item[open] #dummy_help_frame .dummy-thread", text: "Thread a"
    assert page.evaluate_script("document.getElementById('dummy_help_frame') === window.__frame")
    assert_equal "half a reply", find("#dummy_help_reply").value

    set_cookie("dock_tray_frame", "b") # the same id, another thread
    page.execute_script("Turbo.visit('/')")
    assert_selector ".chats-tray__item[open] #dummy_help_frame .dummy-thread", text: "Thread b"
    assert page.evaluate_script("document.getElementById('dummy_help_frame') !== window.__frame")
    assert_equal "", find("#dummy_help_reply").value
  end

  test "two items in the corner at 700px: closed they fit; opened, one takes the sheet, and at 1280 it fits beside" do
    sign_in_at(700, items: "2")

    assert_selector ".chats-tray__item", count: 2
    assert_nothing_overlaps

    find("#chats_tray_help .chats-tray__launcher").click
    assert_selector "#chats_tray_help.chats-tray__item--sheet[open]"
    settle
    sheet = rect("#chats_tray_help")
    assert_equal [0, 0, 700, 900], [sheet["left"], sheet["top"], sheet["width"], sheet["height"]].map(&:round),
                 "no room beside the bar and the other tab: the sheet"
    assert_selector ".dummy-home[inert]", visible: :all
    find("#chats_tray_help .chats-tray__close-glyph").click
    assert_no_selector ".dummy-home[inert]", visible: :all

    resize(1280)
    find("#chats_tray_help .chats-tray__launcher").click
    settle
    assert_no_selector "#chats_tray_help.chats-tray__item--sheet"
    assert_in_delta 336, rect("#chats_tray_help")["width"], 1
    assert_nothing_overlaps
  end

  test "signed out, the tab stands alone in the corner" do
    resize(1280)
    visit "/"
    page.driver.browser.manage.add_cookie(name: "dock_tray", value: "0")
    visit "/"

    assert_selector ".chats-dock--tray-only .chats-tray[data-chats--tray-standalone-value='true']"
    tab = rect(".chats-tray__item")
    assert_in_delta 1280 - 16, tab["right"], 1, "at the dock's inset"
    assert_in_delta page.evaluate_script("window.innerHeight"), tab["bottom"], 1, "on the bottom edge"

    find(".chats-tray__launcher").click
    settle
    assert_selector ".chats-tray__item[open] .dummy-help"
    assert_in_delta 336, rect(".chats-tray__item")["width"], 1

    resize(390, height: 844, mobile: true) # and on a phone, the whole screen
    page.execute_script("document.querySelector('.chats-tray__item').open = false")
    find(".chats-tray__launcher").click
    settle
    sheet = rect(".chats-tray__item")
    assert_equal [0, 0, 390, 844], [sheet["left"], sheet["top"], sheet["width"], sheet["height"]].map(&:round)
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

  def set_cookie(name, value)
    page.driver.browser.manage.add_cookie(name: name, value: value)
  end

  def sign_in_at(width, height: 900, mobile: false, query: "", items: nil)
    resize(width, height: height, mobile: mobile)
    visit "/"
    page.evaluate_async_script(<<~JS, @alice.to_global_id.to_s)
      const done = arguments[arguments.length - 1];
      localStorage.clear();
      fetch("/test_login", { method: "POST", body: new URLSearchParams({ messager_gid: arguments[0] }) }).then(() => done());
    JS
    page.driver.browser.manage.add_cookie(name: "dock_tray", value: "2")
    page.driver.browser.manage.add_cookie(name: "dock_tray_items", value: items) if items
    visit "/#{query}"
    assert_selector ".chats-dock[data-mode]"
    assert_selector ".chats-tray__item", visible: :all
    settle
  end

  # Until every animation (a sheet rising, a panel's body) has finished.
  def settle
    page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1]
      const finite = document.getAnimations().filter((a) => a.effect?.getTiming().iterations !== Infinity)
      Promise.all(finite.map((a) => a.finished.catch(() => {}))).then(() => done())
    JS
  end

  def resize(width, height: 900, mobile: false)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: width, height: height, deviceScaleFactor: 1, mobile: mobile)
    page.execute_script("window.dispatchEvent(new Event('resize'))") if page.current_url.start_with?("http")
    sleep 0.2
  end

  def open_row(name)
    find("#chats_dock_list a", text: name).click
    using_wait_time(10) { assert_selector ".chats-window .chats-window__name", text: name }
  end

  def rect(selector)
    page.evaluate_script(
      "JSON.parse(JSON.stringify(document.querySelector(#{selector.to_json}).getBoundingClientRect()))"
    )
  end

  # Every surface on the bottom edge (windows, the tray's items, the panel),
  # left to right: on screen, and none over the next.
  def assert_nothing_overlaps
    boxes = page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll(".chats-window, .chats-tray__item, .chats-dock__panel"))
        .map((el) => ({ name: el.className.split(" ")[0], ...JSON.parse(JSON.stringify(el.getBoundingClientRect())) }))
        .sort((a, b) => a.left - b.left)
    JS
    viewport = page.evaluate_script("window.innerWidth")
    boxes.each do |box|
      assert_operator box["left"], :>=, 0, "#{box["name"]} starts on screen"
      assert_operator box["right"], :<=, viewport, "#{box["name"]} ends on screen"
    end
    boxes.each_cons(2) do |left, right|
      assert_operator left["right"], :<=, right["left"] + 0.5, "#{left["name"]} and #{right["name"]} overlap"
    end
  end
end
