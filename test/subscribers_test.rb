# frozen_string_literal: true

require "test_helper"

# `Chats.on` — many subscribers per event, each isolated, reload-safe.
class SubscribersTest < ActiveSupport::TestCase
  setup do
    @alice = create_user(name: "Alice")
    @bob = create_user(name: "Bob")
    @carol = create_user(name: "Carol")
  end

  # --- registration ---------------------------------------------------------

  test "every documented event is registrable and unknown ones fail loudly" do
    assert_equal %i[message_created conversation_created participant_left conversation_read],
                 Chats::Subscribers::EVENTS.keys

    Chats::Subscribers::EVENTS.each_key { |event| Chats.on(event) { nil } }

    error = assert_raises(Chats::ConfigurationError) { Chats.on(:message_deleted) { nil } }
    assert_match(/unknown chats event :message_deleted/, error.message)
    assert_match(/message_created/, error.message) # the actionable part: what IS valid
  end

  test "on requires a block" do
    assert_raises(Chats::ConfigurationError) { Chats.on(:message_created) }
  end

  test "two subscribers both run, in registration order" do
    order = []
    Chats.on(:message_created) { |message| order << [:first, message.body] }
    Chats.on(:message_created) { |message| order << [:second, message.body] }

    @alice.message!(@bob, "hola!")

    assert_equal [[:first, "hola!"], [:second, "hola!"]], order
  end

  test "a raising subscriber is reported and does not stop the others" do
    reported = []
    ran = []
    Chats.on(:message_created) { raise "boom" }
    Chats.on(:message_created) { |message| ran << message.body }

    Rails.error.stub(:report, ->(error, **context) { reported << [error.message, context] }) do
      @alice.message!(@bob, "still delivered")
    end

    assert_equal ["still delivered"], ran
    assert_equal 1, reported.size
    assert_equal "boom", reported.first.first
    assert_equal true, reported.first.last[:handled]
    assert_equal({ event: :message_created }, reported.first.last[:context])
  end

  test "a raising subscriber never breaks the write that emitted it" do
    Chats.on(:message_created) { raise "boom" }

    message = @alice.message!(@bob, "committed anyway")

    assert message.persisted?
  end

  test "re-registering the same key replaces in place instead of stacking" do
    calls = []
    3.times do |generation|
      Chats.on(:message_created, key: :host_notifier) { calls << generation }
    end
    Chats.on(:message_created) { calls << :keyless }

    @alice.message!(@bob, "reloaded twice")

    # The last generation of the keyed subscriber, once — and it kept its
    # registration position (first), which is what makes reloads boring.
    assert_equal [2, :keyless], calls
  end

  test "reset_subscribers! clears every registration" do
    fired = []
    Chats.on(:message_created) { fired << :yes }

    Chats.reset_subscribers!
    @alice.message!(@bob, "nobody is listening")

    assert_empty fired
  end

  # --- payloads -------------------------------------------------------------

  test "message_created yields the message and skips system messages" do
    received = []
    Chats.on(:message_created) { |message| received << message }

    conversation = @alice.chat_with(@bob)
    message = @alice.message!(conversation, "human")
    conversation.post_system_message!("the app speaking")

    assert_equal [message], received
  end

  test "conversation_created fires once per conversation, never on resume" do
    created = []
    Chats.on(:conversation_created) { |conversation| created << conversation }

    conversation = @alice.chat_with(@bob)
    @bob.chat_with(@alice) # resumes the same thread
    group = @alice.chat_with(@bob, @carol, title: "Trip")

    assert_equal [conversation, group], created
  end

  test "participant_left fires when someone leaves a group" do
    left = []
    Chats.on(:participant_left) { |participant| left << participant }

    group = @alice.chat_with(@bob, @carol, title: "Trip")
    seat = group.participant_for(@carol)
    seat.leave!

    assert_equal [seat], left
  end

  test "conversation_read yields keywords when a read consumes unread content" do
    received = []
    Chats.on(:conversation_read) { |conversation:, participant:| received << [conversation, participant] }

    conversation = @alice.chat_with(@bob)
    @bob.message!(conversation, "unread")
    conversation.mark_read_by!(@alice)
    conversation.participant_for(@alice).read!(at: 1.minute.from_now) # nothing left to consume

    assert_equal [[conversation, conversation.participant_for(@alice)]], received
  end

  # --- the deprecated single hook -------------------------------------------

  test "config.notifier still receives every event, and says it is deprecated" do
    events = []

    assert_deprecated(/config\.notifier is deprecated/, Chats.deprecator) do
      Chats.config.notifier = ->(event, **payload) { events << [event, payload.keys] }
    end

    @alice.message!(@bob, "hola!")

    assert_equal %i[conversation_created message_created], events.map(&:first)
    assert_equal [%i[conversation], %i[message]], events.map(&:last)
  end

  test "re-assigning config.notifier replaces the old hook instead of stacking" do
    calls = []
    Chats.config.notifier = ->(_event, **) { calls << :old }
    Chats.config.notifier = ->(_event, **) { calls << :new }

    @alice.message!(@bob, "hola!")

    assert_equal %i[new new], calls # conversation_created + message_created
  end

  test "config.notifier and Chats.on coexist" do
    calls = []
    Chats.config.notifier = ->(event, **) { calls << [:hook, event] }
    Chats.on(:message_created) { calls << %i[subscriber message_created] }

    @alice.message!(@bob, "hola!")

    assert_includes calls, %i[hook message_created]
    assert_includes calls, %i[subscriber message_created]
  end
end
