# frozen_string_literal: true

require "test_helper"

# Full request-cycle coverage of the inbox + thread surfaces, including every
# authorization negative: outsiders, leavers, and blocked pairs must all see
# plain 404s (no existence leaks).
class ConversationsFlowTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier

  setup do
    @alice = create_user(name: "Alice")
    @bob = create_user(name: "Bob")
    @carol = create_user(name: "Carol")
    @conversation = conversation_between(@alice, @bob)
  end

  # --- auth ---------------------------------------------------------------------

  test "everything requires authentication" do
    get "/messages"
    assert_response :unauthorized

    get "/messages/#{@conversation.id}"
    assert_response :unauthorized
  end

  # --- inbox ---------------------------------------------------------------------

  test "the inbox lists conversations with previews and unread badges" do
    @bob.message!(@conversation, "are you coming?")
    login_as @alice

    get "/messages"
    assert_response :success
    assert_includes response.body, "Bob"                       # counterpart name
    assert_includes response.body, "are you coming?"           # preview
    assert_includes response.body, "chats-row--unread"         # unread state
    assert_includes response.body, "/messages/#{@conversation.id}" # row link
  end

  test "the inbox renders Active Storage variant avatars inside the mounted engine" do
    @bob.avatar.attach(io: StringIO.new(PNG_BYTES), filename: "avatar.png", content_type: "image/png")
    Chats.config.messager_avatar = lambda do |messager|
      messager.avatar.variant(resize_to_limit: [32, 32]) if messager.avatar.attached?
    end

    @bob.message!(@conversation, "are you coming?")
    login_as @alice

    get "/messages"

    assert_response :success
    assert_includes response.body, "/rails/active_storage/representations/"
    assert_includes response.body, "avatar.png"
  end

  test "the inbox shows the subject context line" do
    listing = create_listing(title: "Madrid → Barcelona")
    @alice.chat_with(@bob, about: listing)
    login_as @alice

    get "/messages"
    assert_includes response.body, "Madrid → Barcelona"
  end

  test "the inbox subscribes to the viewer's inbox stream" do
    login_as @alice
    get "/messages"

    assert_includes response.body, "turbo-cable-stream-source"
  end

  test "the inbox hides blocked direct threads" do
    block_pair!(@alice, @bob)
    login_as @alice

    get "/messages"
    assert_not_includes response.body, "/messages/#{@conversation.id}"
  end

  test "search filters by message body" do
    @bob.message!(@conversation, "el código del maletero es 4242")
    other = conversation_between(@alice, @carol)
    @carol.message!(other, "nos vemos en la gasolinera")
    login_as @alice

    get "/messages", params: { q: "maletero" }
    assert_select "form[data-controller='chats--debounced-submit'][data-turbo-frame='chats_inbox_results']"
    assert_select "turbo-frame#chats_inbox_results[target='_top']"
    assert_includes response.body, "maletero"
    assert_not_includes response.body, "gasolinera"

    get "/messages", params: { q: "zzz-nothing" }
    assert_includes response.body, "zzz-nothing" # the empty state echoes the query
  end

  test "search matches partial participant names conversation titles and subject labels" do
    listing = create_listing(title: "Madrid → Barcelona")
    subject_conversation = conversation_between(@alice, @bob, about: listing)
    group = Chats::Conversation.group!(@alice, [@bob, @carol], title: "Aeropuerto temprano")
    login_as @alice

    get "/messages", params: { q: "bo" }
    assert_includes response.body, "/messages/#{@conversation.id}"

    get "/messages", params: { q: "barce" }
    assert_includes response.body, "/messages/#{subject_conversation.id}"
    assert_not_includes response.body, "/messages/#{@conversation.id}"

    get "/messages", params: { q: "aerop" }
    assert_includes response.body, "/messages/#{group.id}"
  end

  # --- thread ---------------------------------------------------------------------

  test "the thread renders messages and marks them read" do
    @bob.message!(@conversation, "ping")
    assert_equal 1, @conversation.unread_count_for(@alice)

    login_as @alice
    get "/messages/#{@conversation.id}"

    assert_response :success
    assert_includes response.body, "ping"
    assert_includes response.body, dom_id(@conversation, :messages)
    assert_includes response.body, "data-chats--thread-sent-label-value=\"Sent\""
    assert_includes response.body, "data-chats--thread-today-label-value=\"Today\""
    assert_includes response.body, "data-chats--thread-yesterday-label-value=\"Yesterday\""
    assert_select "[data-controller='chats--thread']" do
      assert_select "[data-chats--thread-seen-label-value='Seen']"
      assert_select "[data-chats--thread-typing-suffix-value='is typing…']"
    end
    assert_select "[role='dialog'][data-chats--thread-target='attachmentDialog'][hidden]"
    assert_select "[data-chats--thread-target='attachmentImage'][src]", 0
    assert_not_includes response.body, "' data-chats--thread-yesterday-label-value"
    assert_equal 0, @conversation.unread_count_for(@alice)
  end

  test "image attachments open in the thread preview instead of navigating" do
    message = @bob.message!(@conversation, "photo", files: [png_upload(filename: "pickup.png")])
    login_as @alice

    get "/messages/#{@conversation.id}"

    assert_response :success
    attachment_link = "##{dom_id(message)} " \
      "a[data-action='chats--thread#openAttachment'][data-attachment-name='pickup.png']"
    assert_select attachment_link do
      assert_select "img[alt='pickup.png']"
    end
    assert_select "##{dom_id(message)} a[target]", 0
    assert_select "[role='dialog'] button[data-action='chats--thread#closeAttachment']"
  end

  test "outsiders and leavers get 404, not 403 — existence never leaks" do
    login_as @carol
    get "/messages/#{@conversation.id}"
    assert_response :not_found

    group = Chats::Conversation.group!(@alice, [@bob, @carol])
    group.participant_for(@carol).leave!
    get "/messages/#{group.id}"
    assert_response :not_found
  end

  test "blocked threads 404 on direct access" do
    block_pair!(@alice, @bob)
    login_as @alice

    get "/messages/#{@conversation.id}"
    assert_response :not_found
  end

  test "older pages stream through the keyset pagination frame" do
    Chats.config.messages_per_page = 2
    5.times { |i| @alice.message!(@conversation, "m#{i}") }
    login_as @alice

    get "/messages/#{@conversation.id}"
    assert_includes response.body, "m4"
    assert_includes response.body, "m3"
    assert_not_includes response.body, "m2" # older page, behind the frame

    oldest_loaded = @conversation.messages.order(:created_at, :id).where(body: %w[m3 m4]).first
    get "/messages/#{@conversation.id}", params: { before: oldest_loaded.id }
    assert_response :success
    assert_includes response.body, "chats_page_#{oldest_loaded.id}" # matching frame id
    assert_includes response.body, "m2"
    assert_includes response.body, "m1"
    assert_not_includes response.body, "m4"
  end

  # --- creating from host pages ------------------------------------------------------

  test "create opens (or resumes) a direct conversation from signed GlobalIDs" do
    listing = create_listing
    login_as @alice

    assert_difference "Chats::Conversation.count", 1 do
      post "/messages", params: {
        recipient_sgid: @carol.to_sgid(expires_in: nil, for: :chats_recipient).to_s,
        subject_sgid: listing.to_sgid(expires_in: nil, for: :chats_subject).to_s
      }
    end

    conversation = Chats::Conversation.order(:created_at).last
    assert_redirected_to "/messages/#{conversation.id}"
    assert_equal listing, conversation.subject

    # Resuming: same sgids → same conversation, no duplicate.
    assert_no_difference "Chats::Conversation.count" do
      post "/messages", params: {
        recipient_sgid: @carol.to_sgid(expires_in: nil, for: :chats_recipient).to_s,
        subject_sgid: listing.to_sgid(expires_in: nil, for: :chats_subject).to_s
      }
    end
  end

  test "create rejects tampered or wrong-purpose sgids" do
    login_as @alice

    post "/messages", params: { recipient_sgid: "garbage" }
    assert_response :not_found

    # A perfectly valid sgid minted for ANOTHER purpose must not pass.
    post "/messages", params: { recipient_sgid: @carol.to_sgid(for: :something_else).to_s }
    assert_response :not_found

    # A signed non-messager (a Listing) must not pass either.
    post "/messages", params: {
      recipient_sgid: create_listing.to_sgid(expires_in: nil, for: :chats_recipient).to_s
    }
    assert_response :not_found
  end

  test "create surfaces blocked and policy errors as friendly redirects" do
    block_pair!(@alice, @carol)
    login_as @alice

    post "/messages", params: {
      recipient_sgid: @carol.to_sgid(expires_in: nil, for: :chats_recipient).to_s
    }
    assert_redirected_to "/messages/" # the inbox (engine root) is the fallback
    assert_equal I18n.t("chats.flashes.blocked"), flash[:alert]

    Chats.config.blocked_messager_ids = ->(_messager) { [] }
    Chats.config.can_message = ->(_a, _b) { false }
    post "/messages", params: {
      recipient_sgid: @carol.to_sgid(expires_in: nil, for: :chats_recipient).to_s
    }
    assert_equal I18n.t("chats.flashes.not_allowed"), flash[:alert]
  end

  # --- member actions ---------------------------------------------------------------

  test "read advances the horizon" do
    @bob.message!(@conversation, "unread")
    login_as @alice

    post "/messages/#{@conversation.id}/read"
    assert_response :no_content
    assert_equal 0, @conversation.unread_count_for(@alice)
  end

  test "typing pings broadcast the custom action" do
    login_as @alice

    streams = capture_turbo_stream_broadcasts(@conversation) do
      post "/messages/#{@conversation.id}/typing"
      assert_response :no_content
    end
    assert(streams.any? { |stream| stream["action"] == "chats_typing" })
  end

  # A separate test on purpose: the cable :test adapter accumulates
  # broadcasts per-test, so asserting "no broadcasts" after a positive ping
  # in the same test would see the earlier one.
  test "typing pings respect the feature flag" do
    Chats.config.typing_indicators = false
    login_as @alice

    assert_no_turbo_stream_broadcasts(@conversation) do
      post "/messages/#{@conversation.id}/typing"
      assert_response :no_content
    end
  end

  test "mute and unmute toggle the participant flag" do
    login_as @alice

    post "/messages/#{@conversation.id}/mute"
    assert @conversation.participant_for(@alice).reload.muted?

    post "/messages/#{@conversation.id}/unmute"
    refute @conversation.participant_for(@alice).reload.muted?
  end

  test "leaving works for groups and 404s for direct threads" do
    group = Chats::Conversation.group!(@alice, [@bob, @carol])
    login_as @carol

    post "/messages/#{group.id}/leave"
    assert_redirected_to "/messages/"
    assert group.participant_for(@carol).reload.left?

    login_as @alice
    post "/messages/#{@conversation.id}/leave"
    assert_response :not_found
  end
end
