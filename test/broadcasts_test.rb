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
    assert_includes append.to_html, "data-chats-message-receipt"
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

  test "the badge counts what the inbox shows: a conversation inbox_scope hides never lights it" do
    hidden = conversation_between(@alice, @bob, about: create_listing(title: "Hidden"))
    Chats.config.inbox_scope = ->(relation, _viewer) { relation.where(subject_id: nil) }

    badge_streams = capture_turbo_stream_broadcasts([@bob, :chats_badge]) do
      perform_enqueued_jobs do
        hidden.messages.create!(sender: @alice, body: "out of scope")
      end
    end

    update = badge_streams.find { |stream| stream["action"] == "replace" }
    assert update, "the badge is still re-rendered"
    assert_not_includes update.to_html, ">1<", "the hidden conversation must not be counted"
  end

  # --- the messaging dock's stream ---------------------------------------------

  test "a new message replaces the recipient's dock badge, naming the conversation and popping it up" do
    streams = capture_turbo_stream_broadcasts([@bob, :chats_dock]) do
      perform_enqueued_jobs { @conversation.messages.create!(sender: @alice, body: "dock me") }
    end

    replace = streams.sole
    assert_equal "replace", replace["action"]
    assert_equal "chats_dock_badge", replace["target"]
    badge = dock_badge(replace)
    assert_equal @conversation.id.to_s, badge["data-latest-conversation-id"]
    assert badge.key?("data-changed"), "the dock's signal to reload its list"
    assert badge.key?("data-pop-up"), "and to open the window"
    assert_includes badge.text, "1 unread conversation"
  end

  test "the sender's own dock gets nothing for their own message" do
    assert_no_turbo_stream_broadcasts([@alice, :chats_dock]) do
      perform_enqueued_jobs { @conversation.messages.create!(sender: @alice, body: "mine") }
    end
  end

  test "a muted seat's dock badge stays truthful but never pops a window" do
    @conversation.participant_for(@bob).mute!

    streams = capture_turbo_stream_broadcasts([@bob, :chats_dock]) do
      perform_enqueued_jobs { @conversation.messages.create!(sender: @alice, body: "shh") }
    end

    badge = dock_badge(streams.sole)
    assert_includes badge.text, "1 unread conversation", "muting silences, it doesn't hide"
    assert_equal @conversation.id.to_s, badge["data-latest-conversation-id"]
    assert_not badge.key?("data-pop-up")
  end

  test "a system message pops every seat's window, and a headless seat's never" do
    desk = create_desk(name: "Soporte")
    support = @alice.chat_with(desk)

    alice_streams = capture_turbo_stream_broadcasts([@alice, :chats_dock]) do
      desk_streams = capture_turbo_stream_broadcasts([desk, :chats_dock]) do
        perform_enqueued_jobs { support.post_system_message!("Ticket opened") }
      end
      assert_not dock_badge(desk_streams.sole).key?("data-pop-up"), "a desk is never notified"
    end

    assert dock_badge(alice_streams.sole).key?("data-pop-up")
  end

  test "reading replaces the reader's dock badge without naming anything to open" do
    perform_enqueued_jobs { @conversation.messages.create!(sender: @bob, body: "read me") }

    streams = capture_turbo_stream_broadcasts([@alice, :chats_dock]) do
      perform_enqueued_jobs { @conversation.mark_read_by!(@alice) }
    end

    badge = dock_badge(streams.sole)
    assert badge.key?("data-changed"), "the list reloads: the row is no longer bold"
    assert_nil badge["data-latest-conversation-id"]
    assert_not badge.key?("data-pop-up")
    assert badge.key?("hidden"), "nothing unread left"
  end

  test "the dock badge counts exactly what the nav badge counts" do
    hidden = conversation_between(@alice, @bob, about: create_listing(title: "Hidden"))
    Chats.config.inbox_scope = ->(relation, _viewer) { relation.where(subject_id: nil) }

    streams = capture_turbo_stream_broadcasts([@bob, :chats_dock]) do
      perform_enqueued_jobs { hidden.messages.create!(sender: @alice, body: "out of scope") }
    end

    assert dock_badge(streams.sole).key?("hidden"), "a conversation the inbox hides never lights it"
  end

  test "edits and deletes never touch the dock" do
    message = perform_enqueued_jobs { @conversation.messages.create!(sender: @alice, body: "v1") }

    # capture, not assert_no_…: that one counts every broadcast the stream
    # ever had, the create's included.
    streams = capture_turbo_stream_broadcasts([@bob, :chats_dock]) do
      perform_enqueued_jobs do
        message.edit!("v2")
        message.soft_delete!
      end
    end

    assert_empty streams
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

  private

  # The badge element a dock stream's replace carries.
  def dock_badge(stream)
    stream.at_css("template").inner_html.then { |html| Nokogiri::HTML5.fragment(html) }.at_css("#chats_dock_badge")
  end
end
