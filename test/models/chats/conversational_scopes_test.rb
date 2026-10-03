# frozen_string_literal: true

require "test_helper"

module Chats
  # "Did anyone actually say anything here?" System lines bump
  # messages_count and last_message like any message (the inbox needs
  # them), so a reader that wants real conversations asks these instead.
  class ConversationalScopesTest < ActiveSupport::TestCase
    setup do
      @alice = create_user(name: "Alice")
      @bob = create_user(name: "Bob")
      @carol = create_user(name: "Carol")
      @dave = create_user(name: "Dave")

      # Someone wrote something.
      @talked = conversation_between(@alice, @bob)
      @hello = @alice.message!(@talked, "hola")
      @talked.post_system_message!("Bob se ha unido al chat")

      # Only the app has spoken.
      @system_only = conversation_between(@alice, @carol)
      @system_only.post_system_message!("Se ha creado el chat del viaje")

      # Someone wrote, then deleted it: a tombstone says nothing.
      @retracted = conversation_between(@alice, @dave)
      @alice.message!(@retracted, "oops").soft_delete!
      @retracted.post_system_message!("Dave ha salido del chat")

      # Nothing at all yet.
      @empty = conversation_between(@bob, @carol)
    end

    # --- Message.conversational -------------------------------------------------

    test "conversational keeps standing text messages and drops system lines and tombstones" do
      kept = Message.conversational.to_a

      assert_equal [@hello], kept
      assert(Message.where(kind: "system").exists?)
      assert(Message.where.not(deleted_at: nil).exists?)
    end

    test "a photo without a caption is something a person said" do
      photo = @bob.message!(@empty, nil, files: [png_upload])

      assert_includes Message.conversational, photo
    end

    test "conversational composes with the other message scopes" do
      later = @bob.message!(@talked, "¿a qué hora?")

      assert_equal [later, @hello], @talked.messages.conversational.recent_first.to_a
    end

    # --- Conversation.with_conversation / .without_conversation ----------------

    test "with_conversation keeps only threads where someone wrote and it still stands" do
      assert_equal [@talked], Conversation.with_conversation.to_a
    end

    test "without_conversation is the exact complement: system-only, retracted and empty threads" do
      assert_equal [@empty, @retracted, @system_only].map(&:id).sort,
                   Conversation.without_conversation.pluck(:id).sort
      assert_equal Conversation.count,
                   Conversation.with_conversation.count + Conversation.without_conversation.count
      assert_empty Conversation.with_conversation.without_conversation
    end

    test "the scopes move a thread across as soon as a person writes or retracts" do
      @alice.message!(@system_only, "¿sigue en pie?")
      assert_includes Conversation.with_conversation, @system_only.reload

      @hello.soft_delete!
      assert_includes Conversation.without_conversation, @talked.reload
    end

    test "the denormalized counters still count system lines: nothing changes by default" do
      assert_equal 1, @system_only.reload.messages_count
      assert_predicate @system_only.last_message, :system?
    end

    test "the inbox keeps system-only threads, and the scopes compose with it" do
      inbox = Conversation.inbox_for(@alice)

      assert_includes inbox, @system_only
      assert_equal [@talked], inbox.with_conversation.to_a
      assert_equal [@retracted, @system_only].map(&:id).sort, inbox.without_conversation.pluck(:id).sort
    end

    test "the scopes compose with unread_by, which joins chats_messages itself" do
      unread = Conversation.inbox_for(@bob).unread_by(@bob)

      assert_equal [@talked.id], unread.with_conversation.pluck(:id).uniq
      assert_empty unread.without_conversation

      @carol.message!(@empty, "hola Bob")
      assert_equal [@empty.id, @talked.id].sort, unread.with_conversation.pluck(:id).uniq.sort
    end

    test "the scopes are one correlated subquery, not a join that multiplies rows" do
      @bob.message!(@talked, "uno")
      @bob.message!(@talked, "dos")

      statements = capture_sql { assert_equal 1, Conversation.with_conversation.count }

      assert_equal 1, statements.size
      assert_match(/EXISTS/i, statements.first)
      assert_match(/NOT\s*\(?\s*EXISTS/i, Conversation.without_conversation.to_sql)
    end

    # --- Conversation#last_conversational_message --------------------------------

    test "last_conversational_message skips later system lines and tombstones" do
      @bob.message!(@talked, "borrado").soft_delete!
      @talked.post_system_message!("El viaje ha empezado")

      assert_equal @hello, @talked.last_conversational_message
      assert_predicate @talked.reload.last_message, :system?, "the inbox pointer is untouched"
    end

    test "last_conversational_message is nil for a thread nobody wrote in" do
      assert_nil @system_only.last_conversational_message
      assert_nil @retracted.last_conversational_message
      assert_nil @empty.last_conversational_message
    end

    # --- Message.last_conversational_in -----------------------------------------

    test "last_conversational_in returns the newest conversational message of each conversation in one query" do
      newest = @bob.message!(@talked, "¿a qué hora?")
      @talked.post_system_message!("El viaje ha empezado")
      other = @carol.message!(@empty, "hola Bob")

      found = nil
      statements = capture_sql do
        found = Message.last_conversational_in([@talked, @system_only, @retracted, @empty]).index_by(&:conversation_id)
      end

      assert_equal({ @talked.id => newest, @empty.id => other }, found)
      assert_equal 1, statements.size
    end

    test "last_conversational_in breaks a created_at tie the way recent_first does" do
      tied_at = 1.minute.from_now.change(usec: 0)
      travel_to(tied_at) do
        @alice.message!(@talked, "uno")
        @bob.message!(@talked, "dos")
      end

      expected = @talked.messages.conversational.recent_first.first

      assert_equal expected, Message.last_conversational_in([@talked]).first
      assert_equal expected, @talked.last_conversational_message
    end

    test "last_conversational_in takes ids, keeps a chained select out of the ranking, and answers none for nothing" do
      found = Message.last_conversational_in([@talked.id]).select(:id, :conversation_id).to_a

      assert_equal [@hello.id], found.map(&:id)
      assert_not found.first.has_attribute?(:body), "the host narrowed the columns"
      assert_empty Message.last_conversational_in([])
      assert_empty Message.last_conversational_in([@system_only])
    end
  end
end
