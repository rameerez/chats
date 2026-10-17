# frozen_string_literal: true

require "test_helper"

# What a host sees once it gives messages a button and the composer a row of
# its own: the button renders in every place a bubble does (the page, an
# older page inside its lazy frame, the shared broadcast), the composer can
# never set one, and the host's composer buttons sit outside the composer's
# form and leave with it when the thread locks.
class MessageActionsTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier

  SLOT_VIEWS = File.expand_path("../fixtures/slot_views", __dir__)

  setup do
    @alice = create_user(name: "Alice")
    @bob = create_user(name: "Bob")
    @conversation = conversation_between(@alice, @bob)
  end

  # --- the button in the bubble ---------------------------------------------------

  test "the bubble renders the action as a link that navigates the whole page" do
    message = @bob.message!(@conversation, "Let's play!", action: { label: "Join my room", url: "/play/friend/abcd" })
    login_as @alice

    get "/messages/#{@conversation.id}"

    assert_response :success
    assert_select "##{dom_id(message)} .chats-message__bubble > a.chats-message__action", 1 do |links|
      link = links.first
      assert_equal "Join my room", link.text
      assert_equal "/play/friend/abcd", link["href"]
      assert_equal "_top", link["data-turbo-frame"], "a link inside a page frame would navigate the frame"
    end
  end

  test "the button sits after the words, outside the text node the copy action reads" do
    message = @bob.message!(@conversation, "Your invoice is ready", action: { label: "Pay now", url: "/pay" })
    login_as @alice

    get "/messages/#{@conversation.id}"

    assert_equal "Your invoice is ready", css_select("##{dom_id(message)} [data-chats-message-body]").first.text
    bubble = css_select("##{dom_id(message)} .chats-message__bubble").first
    assert_operator bubble.to_html.index("data-chats-message-body"), :<, bubble.to_html.index("chats-message__action")
  end

  test "a message without an action renders no button" do
    @bob.message!(@conversation, "just words")
    login_as @alice

    get "/messages/#{@conversation.id}"

    assert_select ".chats-message__action", 0
  end

  test "the label and url are escaped like any other host content" do
    @bob.message!(@conversation, "careful", action: { label: "<b>Pay</b>", url: "/pay?a=1&b=<2>" })
    login_as @alice

    get "/messages/#{@conversation.id}"

    link = css_select("a.chats-message__action").first
    assert_equal "<b>Pay</b>", link.text, "the label renders as text, never as markup"
    assert_not_includes response.body, "<b>Pay</b>"
    assert_equal "/pay?a=1&b=<2>", link["href"]
  end

  test "a system message carries its button inside the note" do
    message = @conversation.post_system_message!("Your ride was cancelled",
                                                 action: { label: "Book another", url: "/rides/new" })
    login_as @alice

    get "/messages/#{@conversation.id}"

    assert_select "##{dom_id(message)} .chats-message__system.chats-message__system--with-action" do
      assert_select "a.chats-message__action[href='/rides/new'][data-turbo-frame='_top']", text: "Book another"
    end
  end

  test "a plain system note keeps its plain pill" do
    @conversation.post_system_message!("Ride cancelled")
    login_as @alice

    get "/messages/#{@conversation.id}"

    assert_select ".chats-message__system", 1
    assert_select ".chats-message__system--with-action", 0
  end

  test "a tombstone shows no button" do
    message = @bob.message!(@conversation, "Pay me", action: { label: "Pay now", url: "/pay" })
    message.soft_delete!
    login_as @alice

    get "/messages/#{@conversation.id}"

    assert_select "##{dom_id(message)} .chats-message__tombstone"
    assert_select ".chats-message__action", 0
  end

  test "an older page, served into its lazy frame, carries the button with _top too" do
    Chats.config.messages_per_page = 2
    @bob.message!(@conversation, "Let's play!", action: { label: "Join my room", url: "/play/friend/abcd" })
    2.times { |i| @alice.message!(@conversation, "newer #{i}") }
    login_as @alice

    get "/messages/#{@conversation.id}"
    assert_select ".chats-message__action", 0, "the action's message is on the older page"

    anchor = @conversation.messages.where(body: "newer 0").first
    get "/messages/#{@conversation.id}", params: { before: anchor.id }

    assert_response :success
    assert_select "turbo-frame#chats_page_#{anchor.id} a.chats-message__action[data-turbo-frame='_top']",
                  text: "Join my room"
  end

  test "the broadcast render carries the button, viewer-agnostic" do
    streams = capture_turbo_stream_broadcasts(@conversation) do
      perform_enqueued_jobs do
        @bob.message!(@conversation, "Let's play!", action: { label: "Join my room", url: "/play/friend/abcd" })
      end
    end

    append = streams.find { |stream| stream["action"] == "append" }
    assert append, "expected an append on the conversation stream"
    link = append.css("a.chats-message__action").first
    assert link, "the broadcast bubble must carry the action"
    assert_equal "/play/friend/abcd", link["href"]
    assert_equal "_top", link["data-turbo-frame"]
    assert_not_includes append.to_html, "chats-message--own"
  end

  test "soft-deleting broadcasts a tombstone without the button" do
    message = @bob.message!(@conversation, "Pay me", action: { label: "Pay now", url: "/pay" })

    streams = capture_turbo_stream_broadcasts(@conversation) do
      perform_enqueued_jobs { message.soft_delete! }
    end

    replace = streams.find { |stream| stream["action"] == "replace" }
    assert replace
    assert_includes replace.to_html, "chats-message__tombstone"
    assert_empty replace.css(".chats-message__action")
  end

  # --- the composer never sets one ------------------------------------------------

  test "the composer cannot set an action: the params are ignored, the message is sent without one" do
    login_as @alice

    assert_difference "Chats::Message.count", 1 do
      post "/messages/#{@conversation.id}/messages",
           params: { message: { body: "sneaky", action: { label: "Win a prize", url: "/prize" } } },
           as: :turbo_stream
    end

    assert_response :success
    message = @conversation.messages.order(:id).last
    assert_equal "sneaky", message.body
    assert_nil message.action
    assert_not_includes response.body, "chats-message__action"
  end

  test "the composer cannot set an action through a flat param either" do
    login_as @alice

    post "/messages/#{@conversation.id}/messages",
         params: { message: { body: "sneaky", action: "/prize" } },
         as: :turbo_stream

    assert_response :success
    assert_nil @conversation.messages.order(:id).last.action
  end

  # --- the composer_actions slot --------------------------------------------------

  test "no composer_actions slot means no row" do
    login_as @alice

    get "/messages/#{@conversation.id}"

    assert_select ".chats-composer__actions", 0
    assert_select "##{dom_id(@conversation, :composer)}.chats-composer > form.chats-composer__form", 1
  end

  test "the composer_actions slot renders inside the dock and outside the form" do
    login_as @alice

    with_slot_views { get "/messages/#{@conversation.id}" }

    assert_response :success
    dock = "##{dom_id(@conversation, :composer)}.chats-composer"
    assert_select "#{dock} > .chats-composer__actions [data-dummy-slot=composer_actions]", 1
    assert_select "#{dock} > .chats-composer__actions form.button_to button.dummy-create-game", 1
    assert_select "#{dock} > .chats-composer__actions a.dummy-send-location[href='/locations/new']", 1
    assert_select "form.chats-composer__form [data-dummy-slot=composer_actions]", 0
    assert_equal @conversation.id.to_s, css_select("[data-dummy-slot=composer_actions]").first["data-conversation-id"]

    # The actions row comes first, then the composer's own form, which keeps
    # its Stimulus controller and its error slot.
    dock_html = css_select(dock).first.to_html
    assert_operator dock_html.index("chats-composer__actions"), :<, dock_html.index("chats-composer__form")
    assert_select "#{dock} > form.chats-composer__form[data-controller='chats--composer']" do
      assert_select "##{dom_id(@conversation, :composer_errors)}"
      assert_select "textarea.chats-composer__input"
    end
  end

  test "the slot's button_to form is a sibling of the composer's form, never nested in it" do
    login_as @alice

    with_slot_views { get "/messages/#{@conversation.id}" }

    # Read the raw HTML: an HTML parser silently drops a nested <form> start
    # tag, so only the source can prove there was none.
    dock = response.body[/<div id="#{dom_id(@conversation, :composer)}".*?<form[^>]*chats-composer__form/m]
    assert dock, "the dock should open before the composer's form"
    assert_includes dock, "dummy-create-game", "the host's button renders before the composer's form opens"
    assert_equal dock.scan("<form").size - 1, dock.scan("</form>").size,
                 "every host form closes before the composer's form opens"
  end

  test "a locked thread renders neither the composer nor the host's composer buttons" do
    listing = create_listing
    conversation = @alice.chat_with(@bob, about: listing)
    listing.update!(locked: true)
    login_as @alice

    with_slot_views { get "/messages/#{conversation.id}" }

    assert_response :success
    assert_select "##{dom_id(conversation, :composer)}.chats-composer--locked", 1
    assert_select ".chats-composer__actions", 0
    assert_select "[data-dummy-slot=composer_actions]", 0
  end

  test "a thread that locks under an open composer swaps out the whole dock, host buttons included" do
    listing = create_listing
    conversation = @alice.chat_with(@bob, about: listing)
    login_as @alice

    with_slot_views do
      get "/messages/#{conversation.id}"
      assert_select "##{dom_id(conversation, :composer)} [data-dummy-slot=composer_actions]", 1

      listing.update!(locked: true)
      post "/messages/#{conversation.id}/messages",
           params: { message: { body: "sneaking one in" } },
           as: :turbo_stream
    end

    assert_response :unprocessable_entity
    stream = css_select("turbo-stream[action=replace]").first
    assert_equal dom_id(conversation, :composer), stream["target"],
                 "the replace targets the dock that holds the buttons"
    assert_includes stream.to_html, "chats-composer--locked"
    assert_not_includes stream.to_html, "composer_actions"
  end

  test "sending and failing still answer through the composer's streams with the slot present" do
    login_as @alice

    with_slot_views do
      post "/messages/#{@conversation.id}/messages", params: { message: { body: "hola" } }, as: :turbo_stream
      assert_response :success
      assert_includes response.body, dom_id(@conversation, :messages)
      assert_includes response.body, dom_id(@conversation, :composer_errors)

      post "/messages/#{@conversation.id}/messages", params: { message: { body: "" } }, as: :turbo_stream
      assert_response :unprocessable_entity
      assert_includes response.body, %(target="#{dom_id(@conversation, :composer_errors)}")
    end
  end

  private

  # Prepend a view path carrying `chats/slots/_composer_actions` — the way a
  # host (or an engine mounted on top of chats) ships its own slot.
  def with_slot_views
    original = Chats::ApplicationController.view_paths
    Chats::ApplicationController.prepend_view_path(SLOT_VIEWS)
    yield
  ensure
    Chats::ApplicationController.view_paths = original
  end
end
