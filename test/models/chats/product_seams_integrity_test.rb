# frozen_string_literal: true

require "test_helper"

class ProductSeamsIntegrityTest < ActiveSupport::TestCase
  test "row limit cannot let one grouped counterpart evict another" do
    alice = create_user
    first = create_desk(name: "Busy desk")
    second = create_desk(name: "Other desk")
    Chats.config.inbox_limit = 2
    old = conversation_between(alice, second)
    alice.message!(old, "Older but distinct row")
    2.times do
      thread = conversation_between(alice, first, about: create_listing)
      alice.message!(thread, "Busy desk activity")
    end
    rows = Chats::Inbox.for(alice).rows
    assert_equal 2, rows.size, "two rows fit but only the busiest counterpart survived the raw-conversation LIMIT"
  end

  test "conversation created subscribers do not run for rolled back conversations" do
    alice = create_user
    bob = create_user
    events = []
    Chats.on(:conversation_created) { |c| events << c.id }
    Chats::Conversation.transaction(requires_new: true) do
      conversation_between(alice, bob)
      raise ActiveRecord::Rollback
    end
    assert_empty events, "subscriber saw a conversation before the surrounding transaction committed"
  end

  test "departure subscribers do not run for a rolled back departure" do
    alice = create_user
    bob = create_user
    seat = conversation_between(alice, bob).participant_for(alice)
    events = []
    Chats.on(:participant_left) { |participant| events << participant.id }
    Chats::Participant.transaction(requires_new: true) do
      seat.leave!
      raise ActiveRecord::Rollback
    end
    assert_empty events
    assert_not seat.reload.left?
    seat.leave!
    assert_equal [seat.id], events
    seat.leave!
    assert_equal [seat.id], events
  end
end
