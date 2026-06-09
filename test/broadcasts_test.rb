# frozen_string_literal: true

require "test_helper"

# The complete live behavior, asserted over the Action Cable :test adapter.
# All fan-out goes through `_later` jobs, so blocks are wrapped in
# perform_enqueued_jobs — the same execution path production follows
# (Turbo::Streams::*BroadcastJob), just synchronous.
class BroadcastsTest < ActiveSupport::TestCase
  include ActionView::RecordIdentifier # dom_id

  setup do
    @alice = create_user(name: "Alice")
    @bob = create_user(name: "Bob")
    @conversation = conversation_between(@alice, @bob)
  end

  test "a new message appends to the conversation stream, viewer-agnostic" do
    streams = capture_turbo_stream_broadcasts(@conversation) do
      perform_enqueued_jobs do
        @conversation.messages.create!(sender: @alice, body: "live!")
      end
    end

    append = streams.find { |stream| stream["action"] == "append" }
    assert append, "expected an append on the conversation stream"
    assert_equal dom_id(@conversation, :messages), append["target"]
    assert_includes append.to_html, "live!"
    assert_includes append.to_html, %(data-sender-key="#{Chats.messager_key(@alice)}")
    # Viewer-agnostic: no own/other class baked in — that's client-side.
    assert_not_includes append.to_html, "chats-message--own"
  end

  test "a new message refreshes every participant's inbox stream" do
    [@alice, @bob].each do |messager|
      streams = capture_turbo_stream_broadcasts([messager, :chats_inbox]) do
        perform_enqueued_jobs do
          @conversation.messages.create!(sender: @alice, body: "refresh ping")
        end
      end

      assert streams.any? { |stream| stream["action"] == "refresh" },
             "expected a refresh on #{messager.name}'s inbox stream"
    end
  end

  test "a new message updates recipients' badges but not the sender's" do
    badge_streams = capture_turbo_stream_broadcasts([@bob, :chats_badge]) do
      perform_enqueued_jobs do
        @conversation.messages.create!(sender: @alice, body: "badge me")
      end
    end
    # replace (not update): the partial carries the badge element itself.
    update = badge_streams.find { |stream| stream["action"] == "replace" }
    assert update
    assert_equal "chats_unread_badge", update["target"]
    assert_includes update.to_html, ">1<"

    assert_no_turbo_stream_broadcasts([@alice, :chats_badge]) do
      perform_enqueued_jobs do
        @conversation.messages.create!(sender: @alice, body: "still mine")
      end
    end
  end

  test "editing and soft-deleting replace the bubble in place" do
    message = perform_enqueued_jobs { @conversation.messages.create!(sender: @alice, body: "v1") }

    streams = capture_turbo_stream_broadcasts(@conversation) do
      perform_enqueued_jobs { message.edit!("v2") }
    end
    replace = streams.find { |stream| stream["action"] == "replace" }
    assert replace
    assert_equal dom_id(message), replace["target"]
    assert_includes replace.to_html, "v2"

    streams = capture_turbo_stream_broadcasts(@conversation) do
      perform_enqueued_jobs { message.soft_delete! }
    end
    tombstone = streams.find { |stream| stream["action"] == "replace" }
    assert tombstone
    assert_includes tombstone.to_html, "chats-message--deleted"
  end

  test "hard-deleting removes the bubble" do
    Chats.config.deletion = :hard
    message = perform_enqueued_jobs { @conversation.messages.create!(sender: @alice, body: "bye") }

    streams = capture_turbo_stream_broadcasts(@conversation) do
      perform_enqueued_jobs { message.soft_delete! }
    end

    remove = streams.find { |stream| stream["action"] == "remove" }
    assert remove
    assert_equal dom_id(message), remove["target"]
  end

  test "reading broadcasts the read-state payload to the conversation" do
    perform_enqueued_jobs { @conversation.messages.create!(sender: @bob, body: "see me") }

    streams = capture_turbo_stream_broadcasts(@conversation) do
      perform_enqueued_jobs { @conversation.mark_read_by!(@alice) }
    end

    read_state = streams.find { |stream| stream["target"] == dom_id(@conversation, :read_state) }
    assert read_state, "expected a read_state replace"
    assert_includes read_state.to_html, Chats.messager_key(@alice)
  end

  test "read receipts can be turned off" do
    Chats.config.read_receipts = false
    perform_enqueued_jobs { @conversation.messages.create!(sender: @bob, body: "see me not") }

    streams = capture_turbo_stream_broadcasts(@conversation) do
      perform_enqueued_jobs { @conversation.mark_read_by!(@alice) }
    end

    assert_empty(streams.select { |stream| stream["target"] == dom_id(@conversation, :read_state) })
  end

  test "typing broadcasts the custom action with the typist's name and key" do
    streams = capture_turbo_stream_broadcasts(@conversation) do
      Chats::Broadcasts.typing(@conversation, @alice)
    end

    typing = streams.find { |stream| stream["action"] == "chats_typing" }
    assert typing
    assert_equal dom_id(@conversation, :typing), typing["target"]
    assert_equal "Alice", typing["data-name"]
    assert_equal Chats.messager_key(@alice), typing["data-key"]
  end

  test "reactions re-render the bubble for everyone" do
    message = perform_enqueued_jobs { @conversation.messages.create!(sender: @alice, body: "👍?") }

    streams = capture_turbo_stream_broadcasts(@conversation) do
      perform_enqueued_jobs { Chats::Reaction.toggle!(message: message, reactor: @bob, emoji: "👍") }
    end

    replace = streams.find { |stream| stream["action"] == "replace" && stream["target"] == dom_id(message) }
    assert replace
    assert_includes replace.to_html, "👍"
  end
end
