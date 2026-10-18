# frozen_string_literal: true

require "test_helper"
require "capybara/rails"
require "capybara/minitest"
require "selenium-webdriver"

# The thread's catch-up against Turbo's REAL timing, in headless Chrome: a
# Turbo Stream is performed a repaint after it's rendered, and a page or a
# dock window can render the conversation again while an answer is on its
# way. The node tests' fakes apply streams at once and can't see either.
#
# The page's fetch is wrapped so the test can hold a catch-up's answer
# after the server built it and before the page gets it, and write to the
# database in that gap. The cable is the test adapter: nothing arrives
# live, so whatever the test writes is, to the page, a missed broadcast.
#
# Chrome is a prerequisite in CI (ENV["CI"]), as for the dock's layout
# tests; locally they skip without it. The suite's output says how many ran.
class ThreadCatchUpBrowserTest < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [1280, 900]

  @ran = 0
  @skipped = 0
  class << self
    attr_accessor :ran, :skipped
  end

  Minitest.after_run do
    ran = ThreadCatchUpBrowserTest.ran
    skipped = ThreadCatchUpBrowserTest.skipped
    puts "\nThread catch-up tests (headless Chrome): #{ran} ran, #{skipped} skipped" \
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
    @bob.message!(@conversation, "hola")
  end

  test "a thread more than a page behind is re-rendered, then asks once more, for what came after the page was built" do
    sign_in
    visit "/messages/#{@conversation.id}"
    assert_selector ".chats-thread [data-chats--thread-target='message']", text: "hola"
    hold_catch_up_answers

    (Chats.config.messages_per_page + 1).times { |index| @bob.message!(@conversation, "missed #{index}") }
    catch_up
    wait_until_answered(1)
    @bob.message!(@conversation, "sent after the page was built") # in the gap: not in the answer
    release_answers

    assert_selector ".chats-thread [data-chats--thread-target='message']", text: "sent after the page was built"
    assert_equal 2, refreshes.size, "the re-render, then one more from its cursors"
    assert_equal "1", refreshes.first["history"]
  end

  test "an answer that arrives after the page rendered the conversation again is dropped" do
    sign_in
    visit "/messages/#{@conversation.id}"
    assert_selector ".chats-thread [data-chats--thread-target='message']", text: "hola"
    hold_catch_up_answers

    catch_up
    wait_until_answered(1)
    page.execute_script("Turbo.visit(location.href, { action: 'replace' })") # the same thread, rendered again
    assert_selector ".chats-thread:not([data-chats-render='#{first_render}'])" # the new render is there
    fresh = thread_state
    count_rendered_streams
    release_answers
    sleep 0.5

    assert_equal 0, rendered_streams, "nothing of the old answer reached the new render"
    assert_equal fresh, thread_state, "and the new render's cursors are its own"
  end

  test "an answer that arrives after a dock window loaded its thread again is dropped" do
    sign_in
    visit "/"
    find(".chats-dock__bar").click
    find("#chats_dock_list a", text: "Bob").click
    window = "turbo-frame.chats-window[data-conversation-id='#{@conversation.id}']"
    assert_selector "#{window} [data-chats--thread-target='message']", text: "hola"
    hold_catch_up_answers

    catch_up(window)
    wait_until_answered(1)
    page.execute_script("document.querySelector(#{window.to_json}).reload()") # the window renders it again
    assert_selector "#{window} .chats-thread:not([data-chats-render='#{first_render}'])"
    fresh = thread_state(window)
    count_rendered_streams
    release_answers
    sleep 0.5

    assert_equal 0, rendered_streams
    assert_equal fresh, thread_state(window)
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

  def sign_in
    visit "/"
    page.evaluate_async_script(<<~JS, @alice.to_global_id.to_s)
      const done = arguments[arguments.length - 1];
      localStorage.clear();
      fetch("/test_login", { method: "POST", body: new URLSearchParams({ messager_gid: arguments[0] }) }).then(() => done());
    JS
  end

  # Every catch-up the page asks for is answered by the server at once, and
  # handed to the page only when the test says.
  def hold_catch_up_answers
    page.execute_script(<<~JS)
      window.__refreshes = []
      window.__hold = true
      const realFetch = window.fetch
      window.fetch = async (input, init) => {
        const url = String(input?.url || input)
        if (!url.includes("/refresh?")) return realFetch(input, init)

        const entry = { params: Object.fromEntries(new URL(url, location.href).searchParams), answered: false }
        window.__refreshes.push(entry)
        const response = await realFetch(input, init)
        const body = await response.text()
        entry.answered = true
        if (window.__hold) await new Promise((resolve) => { entry.release = resolve })
        return new Response(body, { status: response.status, headers: response.headers })
      }
    JS
  end

  def release_answers
    page.execute_script("window.__hold = false; window.__refreshes.forEach((entry) => entry.release?.())")
  end

  def wait_until_answered(count)
    Timeout.timeout(Capybara.default_max_wait_time) do
      sleep 0.05 until page.evaluate_script("window.__refreshes.filter((entry) => entry.answered).length") >= count
    end
  end

  def refreshes
    page.evaluate_script("window.__refreshes.map((entry) => entry.params)")
  end

  def catch_up(within = "body")
    page.execute_script(<<~JS, within)
      const element = document.querySelector(arguments[0]).querySelector(".chats-thread")
      window.Stimulus.getControllerForElementAndIdentifier(element, "chats--thread").refreshThread()
    JS
    @first_render = thread_state(within)["render"]
  end

  attr_reader :first_render

  def thread_state(within = "body")
    page.evaluate_script(<<~JS)
      (() => {
        const thread = document.querySelector(#{within.to_json}).querySelector(".chats-thread")
        return { render: thread.dataset.chatsRender, cursors: thread.dataset.chatsReconciled,
                 bubbles: Array.from(thread.querySelectorAll("[data-chats--thread-target='message']")).map((m) => m.id) }
      })()
    JS
  end

  def count_rendered_streams
    page.execute_script(<<~JS)
      window.__rendered = 0
      document.addEventListener("turbo:before-stream-render", () => { window.__rendered++ })
    JS
  end

  def rendered_streams
    page.evaluate_script("window.__rendered")
  end
end
