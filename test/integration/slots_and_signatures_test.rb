# frozen_string_literal: true

require "test_helper"

# The bundled screens, seen from a host that extends them without ejecting
# anything: slots, signed messages, profile links, and the block affordance
# that disappears against a headless messager.
class SlotsAndSignaturesTest < ActionDispatch::IntegrationTest
  setup do
    @alice = create_user(name: "Alice")
    @bob = create_user(name: "Bob")
    @lucia = create_user(name: "Lucía Gómez")
    @desk = create_desk(name: "Soporte")
  end

  # --- slots ----------------------------------------------------------------

  test "an existing slot partial renders and an absent one costs nothing" do
    @alice.chat_with(@bob)
    login_as @alice

    get "/messages"

    assert_response :success
    assert_equal "Need help? Write to us", css_select("[data-dummy-slot=inbox_top]").first.text
    assert_empty css_select("[data-dummy-slot=inbox_empty]"), "the dummy ships no inbox_empty slot"
  end

  test "the message_meta slot renders once per bubble" do
    conversation = @alice.chat_with(@bob)
    2.times { |index| @alice.message!(conversation, "line #{index}") }
    login_as @alice

    get "/messages/#{conversation.id}"

    assert_equal 2, css_select("[data-dummy-slot=message_meta]").size
  end

  test "the conversation_header_actions slot renders block affordances only for blockable counterparts" do
    with_bob = @alice.chat_with(@bob)
    with_desk = @alice.chat_with(@desk)
    login_as @alice

    get "/messages/#{with_bob.id}"
    assert_equal 1, css_select("[data-dummy-slot=conversation_header_actions] .dummy-block-button").size
    assert_equal "true", css_select(".chats-thread").first["data-chats-blockable"]

    get "/messages/#{with_desk.id}"
    assert_equal 1, css_select("[data-dummy-slot=conversation_header_actions]").size, "the slot still renders"
    assert_empty css_select(".dummy-block-button"), "but a headless messager can't be blocked"
    assert_equal "false", css_select(".chats-thread").first["data-chats-blockable"]
  end

  # --- signatures -----------------------------------------------------------

  test "a signed message renders its signature and an unsigned one does not" do
    conversation = @alice.chat_with(@desk)
    @desk.message!(conversation, "On it!", author: @lucia)
    @alice.message!(conversation, "thanks")
    login_as @alice

    get "/messages/#{conversation.id}"

    assert_response :success
    signatures = css_select("[data-chats-message-signature]")
    assert_equal 1, signatures.size
    assert_equal "— Lucía Gómez", signatures.first.text
  end

  test "config.message_signature rewrites the line" do
    Chats.config.message_signature = ->(message) { "respondido por #{Chats.display_name_for(message.author)}" }
    conversation = @alice.chat_with(@desk)
    @desk.message!(conversation, "On it!", author: @lucia)
    login_as @alice

    get "/messages/#{conversation.id}"

    assert_equal "respondido por Lucía Gómez", css_select("[data-chats-message-signature]").first.text
  end

  # --- profile links --------------------------------------------------------

  test "no messager_url means no anchor anywhere" do
    conversation = @alice.chat_with(@bob)
    login_as @alice

    get "/messages/#{conversation.id}"

    assert_response :success
    title = css_select(".chats-thread__title").first
    assert_equal "Bob", title.text.strip
    assert_empty title.css("a"), "the gem never assumes a profile route exists"
  end

  test "messager_url links names to profiles, in the thread and in group bubbles" do
    Chats.config.messager_url = ->(messager) { "/people/#{messager.id}" }
    group = @alice.chat_with(@bob, @lucia, title: "Trip")
    @bob.message!(group, "hola")
    direct = @alice.chat_with(@bob)
    login_as @alice

    get "/messages/#{direct.id}"
    assert_equal "/people/#{@bob.id}", css_select(".chats-thread__title a").first["href"]

    get "/messages/#{group.id}"
    assert_equal "/people/#{@bob.id}", css_select("a.chats-message__sender").first["href"]
  end

  test "messager_url must be callable" do
    assert_raises(Chats::ConfigurationError) { Chats.config.messager_url = "/people" }
  end
end
