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
# Chrome is a prerequisite in CI (ENV["CI"]): a browser that can't start
# FAILS these tests there, so a green build can't mean none of them ran.
# On a machine without Chrome they skip. Either way the suite's output says
# how many ran (see the after_run hook below).
class DockLayoutTest < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [1800, 1000] do |options|
    options.add_option("goog:loggingPrefs", { browser: "ALL" }) # printed when a test fails
  end

  @ran = 0
  @skipped = 0
  class << self
    attr_accessor :ran, :skipped
  end

  Minitest.after_run do
    puts "\nDock layout tests (headless Chrome): #{DockLayoutTest.ran} ran, #{DockLayoutTest.skipped} skipped" \
         "#{" — Chrome unavailable" if DockLayoutTest.skipped.positive?}"
  end

  # A layout failure is a browser failure: show what the page said, and
  # what every frame was answered (recorded from each page's start, see
  # sign_in_at, so nothing is added around the moment under test).
  teardown do
    next if passed? || skipped? || !self.class.chrome?

    page.driver.browser.logs.get(:browser).each { |entry| puts "  [browser #{entry.level}] #{entry.message}" }
    puts page.evaluate_script("(window.chatsTestLog || []).join('\\n')")
  rescue StandardError
    nil
  end

  setup do
    unless self.class.chrome?
      flunk "Chrome could not start, and CI requires it for the dock's layout tests: #{self.class.chrome_error}" if ci?
      self.class.skipped += 1
      skip "Chrome is not available"
    end
    self.class.ran += 1

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

  test "a window refused on its next load keeps its draft, and the draft comes back when it reopens" do
    sign_in_at(1280)
    open_panel
    open_row("Carla")
    type_into("Carla", "words not sent yet")

    # Its next load is refused (the conversation is gone for this viewer, a
    # 404): the window closes…
    page.execute_script("document.querySelector(#{window_selector("Carla").to_json}).src = '/messages/0?window=1'")
    assert_no_selector window_selector("Carla")
    assert_selector ".chats-dock", visible: :all # …without the page leaving for the error

    carla = Chats::Conversation.direct_between(@alice, @people[1])
    draft = page.evaluate_script("localStorage.getItem('chats:draft:#{Chats.messager_key(@alice)}:#{carla.id}')")
    assert_equal "words not sent yet", JSON.parse(draft)["text"], "kept under this viewer's key"

    open_row("Carla")
    within(window_selector("Carla")) do
      assert_field "message[body]", with: "words not sent yet" # it comes back with the conversation
    end
  end

  test "a 5xx keeps what was typed a moment before, under the failure, and gives it back" do
    sign_in_at(1280)
    open_panel
    open_row("Carla")
    # Typed and failed within the 500ms autosave debounce.
    type_into("Carla", "typed just now")
    point_window("Carla", "/test_status/500")

    assert_selector "#{window_selector("Carla")} .chats-window__retry", text: "Try again"
    assert_equal "typed just now", saved_draft("Carla")

    point_window("Carla", "/messages/#{conversation_with("Carla").id}?window=1")
    within(window_selector("Carla")) { assert_field "message[body]", with: "typed just now" }
  end

  test "a network failure keeps what was typed a moment before, under the failure" do
    sign_in_at(1280)
    open_panel
    open_row("Carla")
    type_into("Carla", "typed before the network went")
    point_window("Carla", "http://127.0.0.1:9/unreachable")

    assert_selector "#{window_selector("Carla")} .chats-window__retry"
    assert_equal "typed before the network went", saved_draft("Carla")
  end

  test "a saved draft is restored only into an empty composer, and nothing shorter replaces it" do
    sign_in_at(1280)
    open_panel
    open_row("Carla")
    # The viewer typed before a late restore ran (an ejected composer
    # restores on turbo:frame-load): what they typed stays…
    type_into("Carla", "hi")
    page.execute_script(<<~JS, "#{Chats.messager_key(@alice)}:#{conversation_with("Carla").id}")
      localStorage.setItem("chats:draft:" + arguments[0], JSON.stringify({ text: "a much longer saved draft", at: Date.now() }))
      const dock = document.querySelector(".chats-dock")
      const frame = dock.querySelector(#{window_selector("Carla").to_json})
      window.Stimulus.getControllerForElementAndIdentifier(dock, "chats--dock").restoreDraft(frame)
    JS
    within(window_selector("Carla")) { assert_field "message[body]", with: "hi" }

    # …and the saved draft stays saved while what's typed is shorter.
    type_into("Carla", " there")
    sleep 0.8
    assert_equal "a much longer saved draft", saved_draft("Carla")

    type_into("Carla", ", now longer than the saved one")
    sleep 0.8
    assert_equal "hi there, now longer than the saved one", saved_draft("Carla")
  end

  test "a reload at 768px brings back the expanded and the folded window, both on screen" do
    sign_in_at(768)
    open_panel
    open_row("Carla")
    type_into("Carla", "draft one")
    open_row("Bruno")
    type_into("Bruno", "draft two")
    assert_equal({ "Carla" => 104, "Bruno" => 336 }, widths)
    sleep 0.7 # drafts are saved 500ms after typing stops

    visit "/"

    assert_selector "#{window_selector("Bruno")} .chats-composer__input"
    assert_selector window_selector("Carla", folded: true)
    assert_equal({ "Carla" => 104, "Bruno" => 336 }, widths, "the arrangement as it was")
    assert_row_on_screen
    within(window_selector("Bruno")) { assert_field "message[body]", with: "draft two" }
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

  # GitHub Actions sets CI=true; an empty or "false" CI is a local run.
  def ci?
    %w[1 true yes].include?(ENV["CI"].to_s.downcase)
  end

  FRAME_LOG = <<~JS
    window.chatsTestLog = [];
    ["turbo:before-fetch-response", "turbo:fetch-request-error", "turbo:frame-missing", "turbo:visit"].forEach((name) =>
      document.addEventListener(name, (event) => window.chatsTestLog.push(
        `${performance.now().toFixed(0)} ${name} ${event.target.id || event.target.tagName} ` +
        `${event.detail?.fetchResponse?.statusCode || event.detail?.url || ""}`), true))
  JS

  def sign_in_at(width, height: 900, mobile: false, dock_windows: nil)
    page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: FRAME_LOG)
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
    "turbo-frame.chats-window[data-conversation-id='#{conversation_with(name).id}']" \
      "#{".chats-window--minimized" if folded}"
  end

  def conversation_with(name)
    Chats::Conversation.direct_between(@alice, @people.find { |person| person.name == name })
  end

  # Load something else into a window's frame.
  def point_window(name, url)
    page.execute_script("document.querySelector(#{window_selector(name).to_json}).src = #{url.to_json}")
  end

  # The draft saved for this viewer and conversation, or nil.
  def saved_draft(name)
    raw = page.evaluate_script(
      "localStorage.getItem('chats:draft:#{Chats.messager_key(@alice)}:#{conversation_with(name).id}')"
    )
    raw && JSON.parse(raw)["text"]
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
