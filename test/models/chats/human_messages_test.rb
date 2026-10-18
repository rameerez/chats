# frozen_string_literal: true

require "test_helper"

module Chats
  # "Did a person actually write here?" A system line is a message (it bumps
  # messages_count and last_message, and `with_messages` lists its thread,
  # because "Your ride was cancelled" matters to the person reading it), and
  # a tombstone is still a message. Ops walls, moderation lists and analytics
  # ask the narrower question, and these answer it.
  class HumanMessagesTest < ActiveSupport::TestCase
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

    # --- Message.human -----------------------------------------------------------

    test "human keeps standing text messages and drops system lines and tombstones" do
      assert_equal [@hello], Message.human.to_a
      assert(Message.where(kind: "system").exists?)
      assert(Message.where.not(deleted_at: nil).exists?)
    end

    test "a photo without a caption is something a person said" do
      photo = @bob.message!(@empty, nil, files: [png_upload])

      assert_nil photo.body
      assert_includes Message.human, photo
      assert_includes Conversation.with_human_messages, @empty
      assert_equal photo, @empty.last_human_message
      assert_equal({ @empty.id => photo }, Message.last_human_in([@empty]).index_by(&:conversation_id))
    end

    test "human composes with the other message scopes" do
      later = @bob.message!(@talked, "¿a qué hora?")

      assert_equal [later, @hello], @talked.messages.human.recent_first.to_a
    end

    # --- Conversation.with_human_messages / .without_human_messages ---------------

    test "with_human_messages keeps only threads where someone wrote and it still stands" do
      assert_equal [@talked], Conversation.with_human_messages.to_a
    end

    test "without_human_messages is the exact complement: system-only, retracted and empty threads" do
      assert_equal [@empty, @retracted, @system_only].map(&:id).sort,
                   Conversation.without_human_messages.pluck(:id).sort
      assert_equal Conversation.count,
                   Conversation.with_human_messages.count + Conversation.without_human_messages.count
      assert_empty Conversation.with_human_messages.without_human_messages
    end

    test "the scopes move a thread across as soon as a person writes or retracts" do
      @alice.message!(@system_only, "¿sigue en pie?")
      assert_includes Conversation.with_human_messages, @system_only.reload

      @hello.soft_delete!
      assert_includes Conversation.without_human_messages, @talked.reload
    end

    test "a hard-deleted message is gone from the answer too" do
      Chats.config.deletion = :hard
      @hello.soft_delete!

      assert_includes Conversation.without_human_messages, @talked
      assert_nil @talked.last_human_message
    end

    test "the denormalized counters still count system lines: nothing changes by default" do
      assert_equal 1, @system_only.reload.messages_count
      assert_predicate @system_only.last_message, :system?
    end

    # --- next to with_messages: a different question -------------------------------

    test "a system-only thread has messages but no human ones" do
      assert_includes Conversation.with_messages, @system_only
      assert_includes Conversation.without_human_messages, @system_only
      assert_not_includes Conversation.with_human_messages, @system_only
    end

    test "a thread whose only message is a tombstone has messages but no human ones" do
      tombstoned = conversation_between(@bob, @dave)
      @bob.message!(tombstoned, "borrado").soft_delete!

      assert_equal 1, tombstoned.reload.messages_count
      assert_includes Conversation.with_messages, tombstoned
      assert_includes Conversation.without_human_messages, tombstoned
      assert_nil tombstoned.last_human_message
    end

    test "they compose with with_messages: listed threads nobody wrote in, and an empty one in neither" do
      assert_equal [@talked], Conversation.with_messages.with_human_messages.to_a
      assert_equal [@retracted, @system_only].map(&:id).sort,
                   Conversation.with_messages.without_human_messages.pluck(:id).sort
      assert_not_includes Conversation.with_messages, @empty
      assert_includes Conversation.without_human_messages, @empty
    end

    # --- composing with the viewer's own relation -------------------------------

    test "the inbox keeps system-only threads, and the scopes compose with it" do
      inbox = Conversation.inbox_for(@alice)

      assert_includes inbox, @system_only
      assert_equal [@talked], inbox.with_human_messages.to_a
      assert_equal [@retracted, @system_only].map(&:id).sort, inbox.without_human_messages.pluck(:id).sort
    end

    test "through messager.chats the host's inbox_scope still applies" do
      about_listing = conversation_between(@alice, create_user(name: "Eve"), about: create_listing)
      @alice.message!(about_listing, "¿sigue disponible?")
      Chats.config.inbox_scope = ->(relation, _viewer) { relation.where(subject_id: nil) }

      assert_equal [@talked], @alice.chats.with_human_messages.to_a
      assert_equal [@talked], @alice.chats.with_messages.with_human_messages.to_a
      assert_equal [@retracted, @system_only].map(&:id).sort, @alice.chats.without_human_messages.pluck(:id).sort
      assert_equal [@hello], Message.last_human_in(@alice.chats.limit(20)).to_a, "the README's page, scoped too"
      assert_equal [about_listing, @talked].map(&:id).sort, Conversation.with_human_messages.pluck(:id).sort,
                   "the global scope is the admin's view: it applies no viewer's rules"
    end

    test "the scopes compose with about" do
      listing = create_listing
      about = conversation_between(@alice, @bob, about: listing)
      about.post_system_message!("Reserva confirmada")

      assert_empty Conversation.about(listing).with_human_messages
      assert_equal [about], Conversation.about(listing).without_human_messages.to_a

      @bob.message!(about, "¡gracias!")
      assert_equal [about], Conversation.about(listing).with_human_messages.to_a
    end

    test "the scopes compose with unread_by, which joins chats_messages itself" do
      unread = Conversation.inbox_for(@bob).unread_by(@bob)

      assert_equal [@talked.id], unread.with_human_messages.pluck(:id).uniq
      assert_empty unread.without_human_messages

      @carol.message!(@empty, "hola Bob")
      assert_equal [@empty.id, @talked.id].sort, unread.with_human_messages.pluck(:id).uniq.sort
    end

    test "the scopes are one correlated subquery, not a join that multiplies rows" do
      @bob.message!(@talked, "uno")
      @bob.message!(@talked, "dos")

      statements = capture_sql { assert_equal 1, Conversation.with_human_messages.count }

      assert_equal 1, statements.size
      assert_match(/EXISTS/i, statements.first)
      assert_match(/NOT\s*\(?\s*EXISTS/i, Conversation.without_human_messages.to_sql)
      assert_equal [@talked.id], Conversation.with_human_messages.pluck(:id)
    end

    test "a Message scope the caller is inside never leaks into the subquery" do
      found = Message.where(kind: "system").scoping { Conversation.with_human_messages.to_a }

      assert_equal [@talked], found
    end

    # --- Conversation#last_human_message ------------------------------------------

    test "last_human_message skips later system lines and tombstones" do
      @bob.message!(@talked, "borrado").soft_delete!
      @talked.post_system_message!("El viaje ha empezado")

      assert_equal @hello, @talked.last_human_message
      assert_predicate @talked.reload.last_message, :system?, "the inbox pointer is untouched"
    end

    test "last_human_message is nil for a thread nobody wrote in" do
      assert_nil @system_only.last_human_message
      assert_nil @retracted.last_human_message
      assert_nil @empty.last_human_message
    end

    # --- Message.last_human_in ----------------------------------------------------

    test "last_human_in returns the newest human message of each conversation in one query" do
      newest = @bob.message!(@talked, "¿a qué hora?")
      @talked.post_system_message!("El viaje ha empezado")
      other = @carol.message!(@empty, "hola Bob")

      found = nil
      statements = capture_sql do
        found = Message.last_human_in([@talked, @system_only, @retracted, @empty]).index_by(&:conversation_id)
      end

      assert_equal({ @talked.id => newest, @empty.id => other }, found)
      assert_equal 1, statements.size
    end

    test "last_human_in takes an unloaded relation as a subquery, still one query" do
      newest = @bob.message!(@talked, "¿a qué hora?")
      page = @alice.chats.with_messages

      found = nil
      statements = capture_sql { found = Message.last_human_in(page).index_by(&:conversation_id) }

      assert_not page.loaded?, "the relation is read inside the query, never loaded first"
      assert_equal({ @talked.id => newest }, found)
      assert_equal 1, statements.size
    end

    test "last_human_in reads a limited page exactly, the derived table MySQL needs" do
      other = @carol.message!(@empty, "hola Bob")
      page = Conversation.with_human_messages.reorder(:id).limit(1)
      first = page.to_a.sole
      expected = first == @talked ? @hello : other

      assert_equal [expected], Message.last_human_in(page.reset).to_a
      assert_equal [expected], Message.last_human_in(page.offset(0)).to_a
    end

    test "last_human_in takes the relations an inbox builds: includes, joins, distinct" do
      @bob.message!(@talked, "otra")
      busy = @bob.chats.unread_by(@bob).includes(:last_message, participants: :messager).distinct

      assert_equal [@talked.id], Message.last_human_in(busy).map(&:conversation_id)
    end

    test "a loaded relation is read from memory: one query, for the messages" do
      page = @alice.chats.load

      statements = capture_sql { assert_equal [@hello], Message.last_human_in(page).to_a }

      assert_equal 1, statements.size
      assert_no_match(/chats_participants/, statements.first, "the page was not queried again")
    end

    test "last_human_in breaks a created_at tie the way recent_first does" do
      tied_at = 1.minute.from_now.change(usec: 0)
      travel_to(tied_at) do
        @alice.message!(@talked, "uno")
        @bob.message!(@talked, "dos")
      end

      expected = @talked.messages.human.recent_first.first

      assert_equal expected, Message.last_human_in([@talked]).first
      assert_equal expected, @talked.last_human_message
    end

    test "last_human_in takes ids and a single record, keeps a chained select out of the ranking, and answers none" do
      found = Message.last_human_in([@talked.id]).select(:id, :conversation_id).to_a

      assert_equal [@hello.id], found.map(&:id)
      assert_not found.first.has_attribute?(:body), "the host narrowed the columns"
      assert_equal [@hello], Message.last_human_in(@talked).to_a
      assert_equal [@hello], Message.select(:id, :conversation_id).last_human_in([@talked]).to_a
      assert_empty(capture_sql { assert_empty Message.last_human_in([]) }, "no ids, no query")
      assert_empty Message.last_human_in([@system_only])
      assert_empty Message.last_human_in(Conversation.none)
    end

    test "last_human_in refuses a relation of something other than conversations" do
      error = assert_raises(ArgumentError) { Message.last_human_in(Participant.all) }

      assert_match(/Chats::Conversation/, error.message)
    end
  end
end
