# frozen_string_literal: true

require "test_helper"

# The inbox refresh goes straight into the job queue when the write
# commits — never into Turbo's in-process debounce timer, where a restart
# inside half a second would drop it — and never before the commit.
# (What happens when a client misses it anyway is chats/recovery's; see
# test/javascript.)
class BroadcastsDurabilityTest < ActiveSupport::TestCase
  setup do
    @alice = create_user(name: "Alice")
    @bob = create_user(name: "Bob")
    @conversation = conversation_between(@alice, @bob)
  end

  REFRESH = %(<turbo-stream method="morph" scroll="preserve" action="refresh"></turbo-stream>)

  test "a new message's inbox refreshes are in the job queue as soon as it commits, real debouncer and all" do
    # turbo-rails swaps in an immediate debouncer under test, which would
    # hide the very delay this is about. Put the production one back.
    with_production_debouncer do
      @conversation.messages.create!(sender: @alice, body: "hola")

      # Synchronously, no waiting: `broadcast_refresh_later_to` would only
      # enqueue these from a timer thread half a second from now.
      [@alice, @bob].each do |messager|
        assert_enqueued_with job: Turbo::Streams::BroadcastStreamJob,
                             args: [[messager, :chats_inbox], { content: REFRESH }]
      end
    end
  end

  test "the refresh morphs and keeps the scroll, whatever the host layout's refresh meta says" do
    streams = capture_turbo_stream_broadcasts([@bob, :chats_inbox]) do
      perform_enqueued_jobs { @conversation.messages.create!(sender: @alice, body: "hola") }
    end

    refresh = streams.find { |stream| stream["action"] == "refresh" }
    assert refresh
    assert_equal "morph", refresh["method"]
    assert_equal "preserve", refresh["scroll"]
    assert_nil refresh["request-id"], "outside a request, there is no tab to skip"
  end

  test "nothing is enqueued before the commit, and nothing at all for a write that rolls back" do
    Chats::Message.transaction do
      @conversation.messages.create!(sender: @alice, body: "not yet")
      assert_no_enqueued_jobs only: Turbo::Streams::BroadcastStreamJob
      raise ActiveRecord::Rollback
    end

    assert_no_enqueued_jobs only: Turbo::Streams::BroadcastStreamJob
  end

  test "a burst of messages sends every subscriber the same refresh each time, so the client runs it once" do
    # Turbo runs one page refresh for refreshes arriving within 150ms of
    # each other (Session#pageRefreshDebouncePeriod), and chats--refresh-inbox
    # reruns one that landed mid-visit: identical frames are what make
    # merging them lose nothing.
    streams = capture_turbo_stream_broadcasts([@bob, :chats_inbox]) do
      perform_enqueued_jobs do
        5.times { |index| @conversation.messages.create!(sender: @alice, body: "burst #{index}") }
      end
    end

    refreshes = streams.select { |stream| stream["action"] == "refresh" }
    assert_equal 5, refreshes.size, "one durable refresh per write: none parked, none merged away on the server"
    assert_equal [REFRESH], refreshes.map(&:to_html).uniq
  end

  test "the job discards a refresh for a messager deleted before it ran" do
    @conversation.messages.create!(sender: @alice, body: "hola")
    @bob.destroy!

    assert_nothing_raised { perform_enqueued_jobs only: Turbo::Streams::BroadcastStreamJob }
  end

  private

  def with_production_debouncer
    immediate = Turbo::ThreadDebouncer.debouncer_class
    Turbo::ThreadDebouncer.debouncer_class = Turbo::Debouncer
    yield
  ensure
    Turbo::ThreadDebouncer.debouncer_class = immediate
  end
end
