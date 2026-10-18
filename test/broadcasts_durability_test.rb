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

  test "an enqueue that fails leaves no marker behind to swallow the next write's refresh" do
    Chats::InboxRefreshJob.stub(:perform_later, ->(*) { raise "queue down" }) do
      assert_raises(RuntimeError) { Chats::Broadcasts.refresh_inbox_of(@bob) }
    end

    assert_enqueued_jobs 1, only: Chats::InboxRefreshJob do
      Chats::Broadcasts.refresh_inbox_of(@bob)
    end
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

  def with_cache(store)
    original = Rails.cache
    Rails.cache = store
    yield
  ensure
    Rails.cache = original
  end
end
