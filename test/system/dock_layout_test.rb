# frozen_string_literal: true

require "test_helper"
require "capybara/rails"
require "capybara/minitest"
require "selenium-webdriver"

# The dock's layout promises, measured in a real headless Chrome against the
# dummy host: what the browser RENDERS, not the controller's arithmetic.
#
#   * every window on screen, never under the panel, never overlapping
#     another — after opening, reopening a folded one, and resizing;
#   * a reopen that can't fit is declined (the window stays folded);
#   * on a phone, a window that disappears gives the list back.
#
# Skipped where no Chrome can be started (Selenium Manager finds the driver).
class DockLayoutTest < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [1800, 1000]

  setup do
    skip "Chrome is not available" unless self.class.chrome?

    @alice = create_user(name: "Alice")
    @people = %w[Bruno Carla Diego Elena].map do |name|
      person = create_user(name: name)
      person.message!(@alice, "hola from #{name}")
      person
    end
  end

  test "reopening a folded window at 768px folds the other one in use, and stays on screen" do
    sign_in_at(768)
    open_panel
    open_row("Carla")
    type_into("Carla", "draft one")
    open_row("Bruno")
    type_into("Bruno", "draft two")

    assert_row_on_screen
    assert_equal({ "Carla" => 104, "Bruno" => 336 }, widths)

    title_of("Carla").click # a folded window: unfold it

    assert_selector window_selector("Bruno", folded: true)
    assert_row_on_screen
    assert_equal({ "Carla" => 336, "Bruno" => 104 }, widths)
    assert_equal ["draft one", "draft two"], drafts.values_at("Carla", "Bruno")
  end

  test "a reopen that can't fit is declined: the window stays folded" do
    sign_in_at(768)
    open_panel
    open_row("Carla")
    type_into("Carla", "draft one")
    open_row("Bruno")
    type_into("Bruno", "draft two")

    resize(700) # one expanded + one folded no longer fits beside the panel
    assert_selector window_selector("Bruno", folded: true)
    assert_row_on_screen
    assert_equal({ "Carla" => 104, "Bruno" => 104 }, widths)

    title_of("Carla").click
    sleep 0.3

    assert_equal({ "Carla" => 104, "Bruno" => 104 }, widths, "no room to unfold: it stays folded")
    assert_row_on_screen
  end

  test "four windows in use, from a wide screen down to 700px: the oldest closes, its draft kept" do
    sign_in_at(1800, dock_windows: 4)
    open_panel
    %w[Bruno Carla Diego Elena].each do |name|
      open_row(name)
      type_into(name, "draft for #{name}")
    end
    assert_equal 4, widths.size
    assert_row_on_screen

    resize(700)

    assert_selector ".chats-window", count: 3
    assert_row_on_screen
    assert widths.values.all?(104), "every window left is folded"
    assert_not_includes widths.keys, "Bruno", "the least recently used went"
    bruno = Chats::Conversation.direct_between(@alice, @people.first)
    draft = page.evaluate_script(
      "localStorage.getItem('chats:draft:#{Chats.messager_key(@alice)}:#{bruno.id}')"
    )
    assert_equal "draft for Bruno", JSON.parse(draft)["text"], "its unsent text is kept"
  end

  test "on a phone, a window whose frame goes missing gives the list back" do
    sign_in_at(390, height: 844, mobile: true)
    find(".chats-dock__bar").click
    open_row("Bruno")
    assert_selector ".chats-window.chats-window--front"
    assert page.evaluate_script("document.querySelector('.chats-dock__panel').inert"), "the list waits behind it"

    # The conversation is gone for this viewer: its window answers 404.
    page.execute_script("document.querySelector('.chats-window--front').src = '/messages/0?window=1'")

    assert_no_selector ".chats-window"
    assert_not page.evaluate_script("document.querySelector('.chats-dock__panel').inert"),
               "the list is reachable again"
    open_row("Carla")
    assert_selector ".chats-window.chats-window--front", text: "Carla"
  end

  # Starting a browser once tells whether this machine can run these.
  def self.chrome?
    return @chrome if defined?(@chrome)

    options = Selenium::WebDriver::Chrome::Options.new(args: ["--headless=new"])
    Selenium::WebDriver.for(:chrome, options: options).quit
    @chrome = true
  rescue StandardError
    @chrome = false
  end

  private

  def sign_in_at(width, height: 900, mobile: false, dock_windows: nil)
    resize(width, height: height, mobile: mobile)
    visit "/"
    page.evaluate_async_script(<<~JS, @alice.to_global_id.to_s)
      const done = arguments[arguments.length - 1];
      localStorage.clear();
      fetch("/test_login", { method: "POST", body: new URLSearchParams({ messager_gid: arguments[0] }) }).then(() => done());
    JS
    visit dock_windows ? "/?dock_windows=#{dock_windows}" : "/"
    assert_selector ".chats-dock[data-mode]"
  end

  def resize(width, height: 900, mobile: false)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: width, height: height, deviceScaleFactor: 1, mobile: mobile)
    page.execute_script("window.dispatchEvent(new Event('resize'))") if page.current_url.start_with?("http")
    sleep 0.2
  end

  def open_panel
    find(".chats-dock__bar").click
    assert_selector "#chats_dock_list li"
  end

  def open_row(name)
    find("#chats_dock_list a", text: name).click
    assert_selector ".chats-window .chats-window__name", text: name
    assert_selector "#{window_selector(name)} .chats-composer__input"
  end

  def type_into(name, text)
    find("#{window_selector(name)} .chats-composer__input").send_keys(text)
  end

  def title_of(name)
    find("#{window_selector(name)} .chats-window__title")
  end

  def window_selector(name, folded: false)
    id = Chats::Conversation.direct_between(@alice, @people.find { |person| person.name == name }).id
    "turbo-frame.chats-window[data-conversation-id='#{id}']#{".chats-window--minimized" if folded}"
  end

  # { name => rendered width } for every window shown.
  def widths
    rendered_windows.to_h { |box| [box["name"], box["width"].round] }
  end

  def drafts
    page.evaluate_script(<<~JS)
      Object.fromEntries(Array.from(document.querySelectorAll('.chats-window')).map((w) =>
        [w.querySelector('.chats-window__title')?.title, w.querySelector('.chats-composer__input')?.value]))
    JS
  end

  def rendered_windows
    page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll('.chats-window'))
        .filter((w) => getComputedStyle(w).display !== 'none')
        .map((w) => {
          const r = w.getBoundingClientRect()
          return { name: w.querySelector('.chats-window__title')?.title, left: r.left, right: r.right, width: r.width }
        })
    JS
  end

  # Every window inside the viewport, left of the panel, none overlapping.
  def assert_row_on_screen
    viewport = page.evaluate_script("window.innerWidth")
    panel = page.evaluate_script(
      "JSON.parse(JSON.stringify(document.querySelector('.chats-dock__panel').getBoundingClientRect()))"
    )
    boxes = rendered_windows.sort_by { |box| box["left"] }

    assert_operator panel["right"], :<=, viewport, "the panel is on screen"
    boxes.each do |box|
      assert_operator box["left"], :>=, 0, "#{box["name"]} starts on screen (#{box.inspect})"
      assert_operator box["right"], :<=, panel["left"], "#{box["name"]} ends before the panel (#{box.inspect})"
    end
    boxes.each_cons(2) do |left, right|
      assert_operator left["right"], :<=, right["left"], "#{left["name"]} and #{right["name"]} overlap"
    end
  end
end
