# frozen_string_literal: true

require "test_helper"

# The inbox refresh goes straight into the job queue when the write
# commits — never into Turbo's in-process debounce timer, where a restart
# inside half a second would drop it — never before the commit, and at
# most one queued per messager: a burst is one job per recipient.
# (What happens when a client misses it anyway is chats/recovery's; see
# test/javascript.)
class BroadcastsDurabilityTest < ActiveSupport::TestCase
  setup do
    @alice = create_user(name: "Alice")
    @bob = create_user(name: "Bob")
    @conversation = conversation_between(@alice, @bob)
  end

  CacheDown = Class.new(StandardError) # what a cache store raises when its server is gone

  REFRESH = %(<turbo-stream action="refresh" method="morph" scroll="preserve"></turbo-stream>)

  test "a new message's inbox refreshes are in the job queue as soon as it commits, real debouncer and all" do
    # turbo-rails swaps in an immediate debouncer under test, which would
    # hide the very delay this is about. Put the production one back.
    with_production_debouncer do
      @conversation.messages.create!(sender: @alice, body: "hola")

      # Synchronously, no waiting: `broadcast_refresh_later_to` would only
      # enqueue these from a timer thread half a second from now.
      [@alice, @bob].each do |messager|
        assert_enqueued_with job: Chats::InboxRefreshJob, args: [messager]
      end
    end
  end

  test "the refresh morphs, keeps the scroll, and names no request" do
    streams = capture_turbo_stream_broadcasts([@bob, :chats_inbox]) do
      perform_enqueued_jobs { @conversation.messages.create!(sender: @alice, body: "hola") }
    end

    refresh = streams.sole
    assert_equal "refresh", refresh["action"]
    assert_equal "morph", refresh["method"], "whatever the host layout's refresh meta says"
    assert_equal "preserve", refresh["scroll"]
    assert_nil refresh["request-id"], "one refresh may stand for several requests' writes"
  end

  test "nothing is enqueued before the commit, and nothing at all for a write that rolls back" do
    Chats::Message.transaction do
      @conversation.messages.create!(sender: @alice, body: "not yet")
      assert_no_enqueued_jobs only: Chats::InboxRefreshJob
      raise ActiveRecord::Rollback
    end

    assert_no_enqueued_jobs only: Chats::InboxRefreshJob
    assert_enqueued_jobs 2, only: Chats::InboxRefreshJob do
      @conversation.messages.create!(sender: @alice, body: "the rollback left nothing queued in its name")
    end
  end

  test "a burst of writes queues one refresh per recipient, and that one refresh broadcasts once" do
    group = Chats::Conversation.group!(@alice, [@bob, create_user(name: "Carol")], title: "Trip")
    recipients = group.participants.active.map(&:messager)
    clear_enqueued_jobs
    Rails.cache.clear

    assert_enqueued_jobs recipients.size, only: Chats::InboxRefreshJob do
      5.times { |index| group.messages.create!(sender: @alice, body: "burst #{index}") }
    end
    assert_equal recipients.map(&:id).sort, refresh_jobs.map { |job| job.first.id }.sort, "one each"

    streams = capture_turbo_stream_broadcasts([@bob, :chats_inbox]) do
      perform_enqueued_jobs only: Chats::InboxRefreshJob
    end
    assert_equal [REFRESH], streams.map(&:to_html)
  end

  test "a write after the queued refresh has started queues the next one" do
    @conversation.messages.create!(sender: @alice, body: "first")
    perform_enqueued_jobs only: Chats::InboxRefreshJob # it started, and took its marker down

    assert_enqueued_jobs 2, only: Chats::InboxRefreshJob do
      @conversation.messages.create!(sender: @alice, body: "after it ran")
    end
  end

  test "a write that finds a refresh still queued is covered by it: that job broadcasts after the write" do
    @conversation.messages.create!(sender: @alice, body: "first")
    clear_enqueued_jobs # the queued job is still pending — this is the moment the next write lands

    assert_no_enqueued_jobs only: Chats::InboxRefreshJob do
      @conversation.messages.create!(sender: @alice, body: "second, same window")
    end
  end

  test "a queued refresh stands for the writes after it only for a while: a lost job holds nothing back for long" do
    @conversation.messages.create!(sender: @alice, body: "its job is lost")
    clear_enqueued_jobs

    travel Chats::Broadcasts::INBOX_REFRESH_PENDING + 1.second do # travel drops sub-seconds
      assert_enqueued_jobs 2, only: Chats::InboxRefreshJob do
        @conversation.messages.create!(sender: @alice, body: "after the marker expired")
      end
    end
  end

  test "no cache to remember a queued refresh means a refresh for every write, never none" do
    with_cache(ActiveSupport::Cache::NullStore.new) do
      assert_enqueued_jobs 4, only: Chats::InboxRefreshJob do
        2.times { |index| @conversation.messages.create!(sender: @alice, body: "no cache #{index}") }
      end
    end
  end

  # The marker goes up before the enqueue, so a write can find it while the
  # enqueue is in flight. These are that interleaving: write B commits and
  # finds A's marker in the middle of A's failing enqueue.
  # Only a marker that is really there means a refresh is queued.
  test "a cache that answers nil to the marker's write (RedisCacheStore when the write fails) can't skip a refresh" do
    Rails.cache.stub(:write, nil) do
      assert_enqueued_jobs 2, only: Chats::InboxRefreshJob do
        2.times { Chats::Broadcasts.refresh_inbox_of(@bob) }
      end
    end
  end

  test "a cache that raises on the marker queues the refresh anyway, and says so to Rails.error" do
    Rails.cache.stub(:write, ->(*) { raise CacheDown, "connection refused" }) do
      assert_error_reported(CacheDown) do
        assert_enqueued_jobs 1, only: Chats::InboxRefreshJob do
          Chats::Broadcasts.refresh_inbox_of(@bob)
        end
      end
    end
  end

  test "a refused write whose marker can't be read back queues the refresh" do
    Rails.cache.stub(:write, false) do
      assert_enqueued_jobs 1, only: Chats::InboxRefreshJob do
        Chats::Broadcasts.refresh_inbox_of(@bob) # nothing there to read: it expired, or was never written
      end
    end
  end

  test "a marker that is really there means the refresh is queued: nothing more is" do
    Chats::Broadcasts.refresh_inbox_of(@bob)
    assert Rails.cache.read("chats:inbox-refresh:#{Chats.messager_key(@bob)}")

    assert_no_enqueued_jobs only: Chats::InboxRefreshJob do
      Chats::Broadcasts.refresh_inbox_of(@bob)
    end
  end

  test "a cache that raises as the job takes the marker down doesn't stop the refresh" do
    Chats::Broadcasts.refresh_inbox_of(@bob)
    streams = capture_turbo_stream_broadcasts([@bob, :chats_inbox]) do
      Rails.cache.stub(:delete, ->(*) { raise CacheDown, "timeout" }) do
        perform_enqueued_jobs only: Chats::InboxRefreshJob
      end
    end
    assert_equal [REFRESH], streams.map(&:to_html)
  end

  test "an enqueue that fails while another write counts on it is tried again, and that job covers both" do
    calls = 0
    flaky = lambda do |messager|
      calls += 1
      raise "queue hiccup" unless calls > 1

      Chats::InboxRefreshJob.new(messager).tap(&:enqueue)
    end

    Chats::InboxRefreshJob.stub(:perform_later, lambda { |messager|
      Chats::Broadcasts.refresh_inbox_of(messager) if calls.zero? # write B, mid-enqueue: finds the marker
      flaky.call(messager)
    }) do
      assert_enqueued_jobs 1, only: Chats::InboxRefreshJob do
        Chats::Broadcasts.refresh_inbox_of(@bob) # write A
      end
    end
    assert_equal 2, calls, "B queued nothing; A tried twice"
  end

  test "when the queue refuses twice, the refresh is broadcast at once, so the write that counted on it has one" do
    writer_b_saw_marker = nil
    refusing = lambda do |messager|
      if writer_b_saw_marker.nil?
        writer_b_saw_marker = !Rails.cache.write("chats:inbox-refresh:#{Chats.messager_key(messager)}", true,
                                                 unless_exist: true)
        Chats::Broadcasts.refresh_inbox_of(messager) # write B, mid-enqueue
      end
      raise "queue down"
    end

    streams = capture_turbo_stream_broadcasts([@bob, :chats_inbox]) do
      Chats::InboxRefreshJob.stub(:perform_later, refusing) do
        assert_nothing_raised { Chats::Broadcasts.refresh_inbox_of(@bob) } # write A: committed, so not raised
      end
    end

    assert writer_b_saw_marker, "B found A's marker and queued nothing"
    assert_equal [REFRESH], streams.map(&:to_html), "broadcast right away, once"
    assert_enqueued_jobs 1, only: Chats::InboxRefreshJob do
      Chats::Broadcasts.refresh_inbox_of(@bob)
    end
  end

  test "a queue that declines the job without raising counts as refusing it, and says so to Rails.error" do
    declined = Chats::InboxRefreshJob.new(@bob)
    declined.enqueue_error = ActiveJob::EnqueueError.new("redis is full")
    def declined.successfully_enqueued? = false

    streams = capture_turbo_stream_broadcasts([@bob, :chats_inbox]) do
      reported = assert_error_reported(ActiveJob::EnqueueError) do
        Chats::InboxRefreshJob.stub(:perform_later, ->(*) { declined }) { Chats::Broadcasts.refresh_inbox_of(@bob) }
      end
      assert_equal "redis is full", reported.error.message, "the adapter's own reason, when it gave one"
    end
    assert_equal [REFRESH], streams.map(&:to_html)

    streams = capture_turbo_stream_broadcasts([@alice, :chats_inbox]) do
      reported = assert_error_reported(ActiveJob::EnqueueError) do
        Chats::InboxRefreshJob.stub(:perform_later, ->(*) { false }) { Chats::Broadcasts.refresh_inbox_of(@alice) }
      end
      assert_match "Chats::InboxRefreshJob was not enqueued", reported.error.message
    end
    assert_equal [REFRESH], streams.map(&:to_html)
  end

  test "a raising enqueue is reported too, once per attempt" do
    reports = errors_reported do
      Chats::InboxRefreshJob.stub(:perform_later, ->(*) { raise "queue down" }) { Chats::Broadcasts.refresh_inbox_of(@bob) }
    end
    assert_equal ["queue down", "queue down"], reports.grep(RuntimeError).map(&:message)
  end

  test "the job discards a refresh for a messager deleted before it ran" do
    @conversation.messages.create!(sender: @alice, body: "hola")
    @bob.destroy!

    assert_nothing_raised { perform_enqueued_jobs only: Chats::InboxRefreshJob }
  end

  private

  def refresh_jobs
    enqueued_jobs.select { |job| job["job_class"] == "Chats::InboxRefreshJob" }
                 .map { |job| ActiveJob::Arguments.deserialize(job["arguments"]) }
  end

  def with_production_debouncer
    immediate = Turbo::ThreadDebouncer.debouncer_class
    Turbo::ThreadDebouncer.debouncer_class = Turbo::Debouncer
    yield
  ensure
    Turbo::ThreadDebouncer.debouncer_class = immediate
  end

  # Every error reported to Rails.error while the block runs. (Rails 8.1's
  # capture_error_reports does this; the gem is tested back to 7.1.)
  def errors_reported
    collector = Class.new do
      attr_reader :errors

      def initialize = @errors = []
      def report(error, **) = @errors << error
    end.new
    Rails.error.subscribe(collector)
    yield
    collector.errors
  ensure
    Rails.error.unsubscribe(collector)
  end

  def with_cache(store)
    original = Rails.cache
    Rails.cache = store
    yield
  ensure
    Rails.cache = original
  end
end
