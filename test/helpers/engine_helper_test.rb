# frozen_string_literal: true

require "test_helper"

class EngineHelperTest < ActionView::TestCase
  include Chats::EngineHelper
  # The bare ActionView::TestCase view doesn't carry Turbo's helpers
  # (chats_unread_badge composes turbo_stream_from).
  include Turbo::StreamsHelper

  setup do
    @alice = create_user(name: "Alice Wonder")
    @bob = create_user(name: "Bob")
  end

  # ActionView::TestCase has no controller auth — emulate the host's
  # current_user the way any host view context exposes it.
  attr_accessor :stubbed_viewer

  def current_user = stubbed_viewer

  test "chat_button_to renders a signed form for a messageable pair" do
    self.stubbed_viewer = @alice
    html = chat_button_to(@bob, label: "Chat with Bob")

    assert_includes html, "Chat with Bob"
    assert_includes html, "recipient_sgid"
    assert_not_includes html, "#{@bob.id}\"" # raw ids never travel
  end

  test "chat_button_to includes the subject sgid when about: is given" do
    self.stubbed_viewer = @alice
    listing = create_listing

    html = chat_button_to(@bob, about: listing)
    assert_includes html, "subject_sgid"
  end

  test "chat_button_to renders nothing for self, nil, blocked, or forbidden pairs" do
    self.stubbed_viewer = @alice

    assert_nil chat_button_to(@alice) # yourself
    assert_nil chat_button_to(nil)

    block_pair!(@alice, @bob)
    assert_nil chat_button_to(@bob)

    Chats.config.blocked_messager_ids = ->(_messager) { [] }
    Chats.config.can_message = ->(_a, _b) { false }
    assert_nil chat_button_to(@bob)

    self.stubbed_viewer = nil
    assert_nil chat_button_to(@bob) # logged out
  end

  test "chats_messager_avatar falls back to initials" do
    html = chats_messager_avatar(@alice)

    assert_includes html, "chats-avatar--initials"
    assert_includes html, "AW"
  end

  test "chats_messager_avatar renders Active Storage variants from engine views" do
    @alice.avatar.attach(io: StringIO.new(PNG_BYTES), filename: "avatar.png", content_type: "image/png")
    Chats.config.messager_avatar = ->(messager) { messager.avatar.variant(resize_to_limit: [32, 32]) }

    html = chats_messager_avatar(@alice)

    assert_includes html, "/rails/active_storage/representations/"
    assert_includes html, "avatar.png"
    assert_includes html, "loading=\"lazy\""
  end

  test "chats_messager_avatar renders Active Storage attachments from engine views" do
    @alice.avatar.attach(io: StringIO.new(PNG_BYTES), filename: "avatar.png", content_type: "image/png")
    Chats.config.messager_avatar = :avatar.to_proc

    html = chats_messager_avatar(@alice)

    assert_includes html, "/rails/active_storage/blobs/"
    assert_includes html, "avatar.png"
    assert_includes html, "loading=\"lazy\""
  end

  test "chats_preview_for prefixes group messages with the sender's first name" do
    carol = create_user(name: "Carol Chofer")
    group = Chats::Conversation.group!(@alice, [@bob, carol], title: "Trip")
    carol.message!(group, "see you at the corner")

    assert_equal "Carol: see you at the corner", chats_preview_for(group.reload, @alice)

    @alice.message!(group, "on my way")
    assert_includes chats_preview_for(group.reload, @alice), I18n.t("chats.inbox.you_prefix")

    group.post_system_message!("Ride cancelled")
    assert_equal "Ride cancelled", chats_preview_for(group.reload, @alice) # system: bare
  end

  test "chats_preview_for summarizes the latest message" do
    conversation = conversation_between(@alice, @bob)
    assert_equal I18n.t("chats.inbox.no_messages"), chats_preview_for(conversation, @alice)

    @alice.message!(conversation, "see you at 8")
    conversation.reload
    preview = chats_preview_for(conversation, @alice)
    assert_includes preview, I18n.t("chats.inbox.you_prefix")
    assert_includes preview, "see you at 8"

    conversation.last_message.soft_delete!
    assert_equal I18n.t("chats.message.deleted"), chats_preview_for(conversation.reload, @alice)
  end

  test "chats_timestamp is compact and locale-independent" do
    assert_equal "", chats_timestamp(nil)
    assert_match(/\A\d{2}:\d{2}\z/, chats_timestamp(Time.current))
    assert_match(%r{\A\d{1,2}/\d{1,2}/\d{2}\z}, chats_timestamp(2.years.ago))
  end

  test "chats_unread_badge renders the live badge with its stream subscription" do
    conversation = conversation_between(@alice, @bob)
    @bob.message!(conversation, "unread!")

    html = chats_unread_badge(@alice)
    assert_includes html, "turbo-cable-stream-source"
    assert_includes html, 'id="chats_unread_badge"'
    assert_includes html, ">1<"
  end
end
