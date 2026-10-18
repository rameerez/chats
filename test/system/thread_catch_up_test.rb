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
    window = open_dock_window
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

  # --- Turbo applying the answer late ---------------------------------------------
  #
  # Turbo performs a stream a repaint after it joins the page. Holding the
  # page's animation frames holds exactly that, for as long as the test
  # likes, and lets it run other frames (a visit's render) first.

  test "a re-render Turbo applies only after 2s still gets its follow-up catch-up" do
    sign_in
    visit "/messages/#{@conversation.id}"
    assert_selector ".chats-thread [data-chats--thread-target='message']", text: "hola"
    hold_catch_up_answers

    (Chats.config.messages_per_page + 1).times { |index| @bob.message!(@conversation, "missed #{index}") }
    catch_up
    wait_until_answered(1)
    @bob.message!(@conversation, "sent after the page was built")
    hold_frames
    release_answers
    wait_for_pending_streams
    sleep 2.5 # past renderStreamFrom's 2s: it must not claim the answer applied
    release_frames

    assert_selector ".chats-thread [data-chats--thread-target='message']", text: "sent after the page was built"
    assert_equal 2, refreshes.size
  end

  test "an answer whose streams are still waiting when the page renders the thread again changes nothing" do
    sign_in
    visit "/messages/#{@conversation.id}"
    assert_selector ".chats-thread [data-chats--thread-target='message']", text: "hola"
    @bob.message!(@conversation, "missed") # the old answer appends it; the new render has it already
    hold_catch_up_answers

    catch_up
    wait_until_answered(1)
    hold_frames
    release_answers
    waiting = wait_for_pending_streams # inserted while the render was still current…
    page.execute_script("Turbo.visit(location.href, { action: 'replace' })") # …then the thread renders again
    run_frames_until_rendered_again(after: waiting)

    assert_no_change_from_old_streams(waiting)
  end

  test "an answer whose streams are still waiting when a dock window loads its thread again changes nothing" do
    sign_in
    window = open_dock_window
    @bob.message!(@conversation, "missed")
    hold_catch_up_answers

    catch_up(window)
    wait_until_answered(1)
    hold_frames
    release_answers
    waiting = wait_for_pending_streams
    page.execute_script("document.querySelector(#{window.to_json}).reload()")
    run_frames_until_rendered_again(within: window, after: waiting)

    # Turbo still hasn't had the frame to apply the old streams: the window
    # re-rendering inside <body> settled the old answer and took them away.
    Timeout.timeout(Capybara.default_max_wait_time) do
      sleep 0.02 until page.evaluate_script("window.__caughtUp") == "settled"
    end
    assert_equal 0, answer_streams_waiting
    assert_no_change_from_old_streams(waiting, within: window)
  end

  test "a dock window carried across a visit while its answer waits still gets the answer" do
    sign_in
    window = open_dock_window
    @bob.message!(@conversation, "missed while the dock moved")
    hold_catch_up_answers

    catch_up(window)
    wait_until_answered(1)
    hold_frames
    release_answers
    waiting = wait_for_pending_streams
    page.execute_script("document.body.dataset.before = 'visit'; Turbo.visit('/')") # the dock is permanent
    Timeout.timeout(Capybara.default_max_wait_time) do
      loop do
        page.execute_script("window.__runFrames(#{waiting}, Infinity)")
        break unless page.evaluate_script("document.body.dataset.before")

        sleep 0.02
      end
    end
    sleep 0.2 # past the task in which a thread that really went away would let its answer go

    assert_equal first_render, thread_state(window)["render"], "the same thread, carried along"
    assert_operator answer_streams_waiting, :>, 0, "its answer still waits"
    release_frames

    assert_selector "#{window} [data-chats--thread-target='message']", text: "missed while the dock moved"
  end

  test "a dock window carried across a visit by a host's asynchronous render still gets the answer" do
    sign_in
    window = open_dock_window
    @bob.message!(@conversation, "missed during a slow render")
    hold_catch_up_answers

    catch_up(window)
    wait_until_answered(1)
    # The host animates its page renders: the new body goes in, then the
    # render takes 1.5s more (an entrance animation) before Turbo moves the
    # permanent dock into it — across many tasks, the dock off the page.
    page.execute_script(<<~JS, window)
      window.__thread = document.querySelector(arguments[0]).querySelector(".chats-thread")
      document.addEventListener("turbo:before-render", (event) => {
        event.detail.render = async (current, next) => {
          current.replaceWith(next)
          await new Promise((resolve) => setTimeout(resolve, 1500))
        }
      }, { once: true })
      document.body.dataset.before = "visit"
      Turbo.visit("/")
    JS
    Timeout.timeout(Capybara.default_max_wait_time) do
      sleep 0.01 while page.evaluate_script("window.__thread.isConnected")
    end
    sleep 0.3 # well past the task a fixed deferral would have waited
    release_answers # the answer arrives while the window is off the page

    assert_selector "#{window} [data-chats--thread-target='message']", text: "missed during a slow render"
    assert_nil page.evaluate_script("document.body.dataset.before"), "on the new page"
    assert page.evaluate_script("window.__thread.isConnected"), "the same thread, carried along"
  end

  test "streams waiting while a host's asynchronous render has the dock off the page still apply to it" do
    sign_in
    window = open_dock_window
    missed = "missed, its stream waiting through a slow render"
    @bob.message!(@conversation, missed)
    hold_catch_up_answers

    catch_up(window)
    wait_until_answered(1)
    hold_frames
    release_answers
    waiting = wait_for_pending_streams # the answer's streams wait for their frame
    page.execute_script(<<~JS, window)
      window.__thread = document.querySelector(arguments[0]).querySelector(".chats-thread")
      document.addEventListener("turbo:before-render", (event) => {
        event.detail.render = async (current, next) => {
          current.replaceWith(next)
          await new Promise((resolve) => setTimeout(resolve, 1500))
        }
      }, { once: true })
      Turbo.visit("/")
    JS
    Timeout.timeout(Capybara.default_max_wait_time) do
      loop do
        page.execute_script("window.__runFrames(#{waiting}, Infinity)") # the visit's frames, not the streams'
        break unless page.evaluate_script("window.__thread.isConnected")

        sleep 0.01
      end
    end
    sleep 0.3 # the window is off the page, past any fixed one-task deferral
    assert_operator answer_streams_waiting, :>, 0, "its answer still waits"
    release_frames # Turbo gets to the streams while the dock is still away

    assert_selector "#{window} [data-chats--thread-target='message']", text: missed
    assert page.evaluate_script("window.__thread.isConnected"), "the same thread, carried along"
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

  # The conversation with Bob in a dock window on a host page. The dock's
  # controller must be connected (it sets data-mode) before a row is
  # clicked, or the click is a plain link to the thread page.
  def open_dock_window
    visit "/"
    assert_selector ".chats-dock[data-mode]"
    find(".chats-dock__bar").click
    assert_selector "#chats_dock_list li"
    find("#chats_dock_list a", text: "Bob").click
    window = "turbo-frame.chats-window[data-conversation-id='#{@conversation.id}']"
    assert_selector "#{window} [data-chats--thread-target='message']", text: "hola"
    window
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
      window.__caughtUp = "waiting"
      window.Stimulus.getControllerForElementAndIdentifier(element, "chats--thread").refreshThread()
        .then(() => { window.__caughtUp = "settled" })
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

  # Holds every animation frame the page asks for, to run when the test says.
  def hold_frames
    page.execute_script(<<~JS)
      window.__frames = []
      window.__realFrame = window.requestAnimationFrame
      window.requestAnimationFrame = (callback) => window.__frames.push(callback)
      window.__runFrames = (from, to) => {
        for (let index = from; index < Math.min(to, window.__frames.length); index++) {
          const callback = window.__frames[index]
          window.__frames[index] = null
          callback?.(performance.now())
        }
      }
    JS
  end

  def release_frames
    page.execute_script(<<~JS)
      window.requestAnimationFrame = window.__realFrame
      window.__runFrames(0, window.__frames.length)
    JS
  end

  # The answer's streams, in <html>, waiting for their frame: how many
  # frames were queued by then (theirs among them).
  def wait_for_pending_streams
    Timeout.timeout(Capybara.default_max_wait_time) do
      sleep 0.02 until page.evaluate_script("document.querySelectorAll('html > turbo-stream').length").positive?
    end
    page.evaluate_script("window.__frames.length")
  end

  # Runs the frames queued after the answer's (the new render's) until the
  # thread has rendered again, and its new controller has booted.
  def run_frames_until_rendered_again(after:, within: "body")
    Timeout.timeout(Capybara.default_max_wait_time) do
      loop do
        page.execute_script("window.__runFrames(#{after}, Infinity)")
        break if thread_state(within)["render"] != first_render

        sleep 0.02
      end
      sleep 0.2
      page.execute_script("window.__runFrames(#{after}, Infinity)")
    end
  end

  # Runs the answer's frames, watching the new render's history: not one
  # node of it may change, and the old streams must be gone.
  def assert_no_change_from_old_streams(frames, within: "body")
    fresh = thread_state(within)
    page.execute_script(<<~JS, within)
      window.__changes = 0
      window.__changeLog = []
      // The history: what the answer's streams address (messages, read state).
      // The dock may resync a window's header controls on its own meanwhile.
      const thread = document.querySelector(arguments[0]).querySelector(".chats-thread .chats-thread__scroll")
      new MutationObserver((records) => {
        window.__changes += records.length
        records.forEach((r) => window.__changeLog.push([r.type, r.target.id || r.target.className, r.attributeName, [...r.addedNodes].map((n) => n.id || n.nodeName).join(" "), [...r.removedNodes].map((n) => n.id || n.nodeName).join(" ")]))
      })
        .observe(thread, { childList: true, subtree: true, attributes: true, characterData: true })
    JS
    page.execute_script("window.__runFrames(0, #{frames})")
    Timeout.timeout(Capybara.default_max_wait_time) do
      sleep 0.02 until page.evaluate_script("document.querySelectorAll('html > turbo-stream').length").zero?
    end
    changes = page.evaluate_script("window.__changes")
    release_frames

    log = page.evaluate_script("window.__changeLog")
    assert_equal 0, changes, "the old answer's streams touched the new render: #{log.inspect}"
    assert_equal fresh, thread_state(within), "its bubbles and cursors are its own"
  end

  def answer_streams_waiting
    page.evaluate_script("document.querySelectorAll('html > turbo-stream[data-chats-answer]').length")
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
