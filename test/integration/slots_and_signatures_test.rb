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

  test "the message_menu slot renders in each bubble's menu, after the gem's own items" do
    conversation = @alice.chat_with(@bob)
    message = @bob.message!(conversation, "report me")
    login_as @alice

    get "/messages/#{conversation.id}"

    menu = css_select("##{ActionView::RecordIdentifier.dom_id(message)} template[data-chats-message-menu]").first
    items = Nokogiri::HTML::DocumentFragment.parse(menu.inner_html).css(".chats-popup__menu > *").to_a
    assert_equal %w[message_menu message_menu_form], items.last(2).map { |item| item["data-dummy-slot"] },
                 "the host's items come last"
    report, pin = items.last(2)
    assert_equal "/?reported=#{message.id}", report["href"]
    assert_equal "true", report["data-chats-other-only"]
    assert_equal "/test_pin/#{message.id}", pin["action"]
    assert_operator items.size, :>, 2, "the gem's own items are still there"
  end

  test "the message_menu slot renders in a broadcast bubble too" do
    conversation = @alice.chat_with(@bob)
    message = @bob.message!(conversation, "live")

    html = ApplicationController.render(partial: "chats/messages/message", locals: { message: message })

    assert_includes html, %(data-dummy-slot="message_menu")
    assert_includes html, "data-chats-message-menu-trigger"
  end

  test "a deleted message has no menu, so neither the slot nor the trigger" do
    conversation = @alice.chat_with(@bob)
    message = @bob.message!(conversation, "gone")
    message.soft_delete!
    login_as @alice

    get "/messages/#{conversation.id}"

    assert_select "##{ActionView::RecordIdentifier.dom_id(message)}" do
      assert_select "template[data-chats-message-menu]", 0
      assert_select "[data-chats-message-menu-trigger]", 0
    end
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
