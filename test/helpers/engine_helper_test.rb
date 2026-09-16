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
    assert_includes html, "loading=\"eager\""
  end

  test "chats_messager_avatar renders Active Storage attachments from engine views" do
    @alice.avatar.attach(io: StringIO.new(PNG_BYTES), filename: "avatar.png", content_type: "image/png")
    Chats.config.messager_avatar = :avatar.to_proc

    html = chats_messager_avatar(@alice)

    assert_includes html, "/rails/active_storage/blobs/"
    assert_includes html, "avatar.png"
    assert_includes html, "loading=\"eager\""
  end

  test "chats_messager_avatar allows lazy loading when a host opts in" do
    @alice.avatar.attach(io: StringIO.new(PNG_BYTES), filename: "avatar.png", content_type: "image/png")
    Chats.config.messager_avatar = :avatar.to_proc

    html = chats_messager_avatar(@alice, loading: "lazy")

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

  # --- 0.2.0 helpers ---------------------------------------------------------

  test "chats_slot renders an existing partial and nothing at all for a missing one" do
    assert chats_slot?(:inbox_top)
    assert_includes chats_slot(:inbox_top), "Need help?"

    assert_not chats_slot?(:inbox_empty)
    assert_nil chats_slot(:inbox_empty)
  end

  test "only the documented slots exist — anything else renders nothing" do
    assert_equal %w[inbox_top inbox_empty conversation_header_actions locked_composer message_meta],
                 Chats::EngineHelper::SLOTS

    assert_not chats_slot?(:inbox_bottom)
    assert_nil chats_slot(:inbox_bottom)
    # A name outside the contract is never even looked up.
    lookup_context.stub(:exists?, ->(*) { raise "looked up an undocumented slot" }) do
      assert_not chats_slot?("../../secrets")
    end
  end

  test "chats_slot? memoizes its lookup per view" do
    assert chats_slot?(:inbox_top)
    assert_not chats_slot?(:inbox_empty)

    # Asking again must not hit the resolver — that's what keeps a slot
    # rendered inside a collection cheap, present or absent.
    lookup_context.stub(:exists?, ->(*) { raise "looked up twice" }) do
      assert chats_slot?(:inbox_top)
      assert_not chats_slot?(:inbox_empty)
    end
  end

  test "chats_messager_name is plain text without messager_url and a link with it" do
    assert_equal "<span>Bob</span>", chats_messager_name(@bob)

    Chats.config.messager_url = ->(messager) { "/people/#{messager.id}" }
    html = chats_messager_name(@bob, css_class: "who")

    assert_includes html, %(href="/people/#{@bob.id}")
    assert_includes html, %(class="who")
    assert_includes html, "Bob"
  end

  test "chats_messager_name renders text when messager_url returns nil for THIS messager" do
    desk = create_desk(name: "Support")
    Chats.config.messager_url = ->(messager) { messager.is_a?(User) ? "/people/#{messager.id}" : nil }

    assert_includes chats_messager_name(@bob), "href"
    assert_not_includes chats_messager_name(desk), "href"
  end

  test "chats_blockable? mirrors the messager declaration" do
    assert chats_blockable?(@bob)
    assert_not chats_blockable?(create_desk)
  end

  test "chats_message_signature returns the line only for signed messages" do
    desk = create_desk(name: "Support")
    conversation = @alice.chat_with(desk)

    assert_equal "— Alice Wonder", chats_message_signature(desk.message!(conversation, "hi", author: @alice))
    assert_nil chats_message_signature(@alice.message!(conversation, "hi"))
  end

  # --- the official-account badge ---------------------------------------------

  test "chats_verified_badge renders nothing for anyone who hasn't declared it" do
    assert_nil chats_verified_badge(@bob)
    assert_nil chats_verified_badge(nil)
    assert_nil chats_verified_badge(create_listing), "a non-messager is never official"
  end

  test "chats_verified_badge renders the labelled rosette for a verified messager" do
    html = chats_verified_badge(create_shop(name: "Tienda Oficial"))

    assert_includes html, %(class="chats-verified")
    assert_includes html, %(role="img")
    assert_includes html, %(aria-label="Official account")
    assert_includes html, %(title="Official account")
    assert_includes html, "<svg"
    assert_includes html, %(aria-hidden="true")
  end

  test "the badge label follows the locale" do
    shop = create_shop(name: "Tienda Oficial")

    I18n.with_locale(:es) { assert_includes chats_verified_badge(shop), %(aria-label="Cuenta oficial") }
    I18n.with_locale(:en) { assert_includes chats_verified_badge(shop), %(aria-label="Official account") }
  end

  test "config.verified_badge hands the messager to the host and uses what comes back" do
    seen = []
    Chats.config.verified_badge = lambda do |messager|
      seen << messager
      ActionController::Base.helpers.tag.i(class: "host-mark")
    end
    shop = create_shop(name: "Tienda Oficial")

    assert_equal %(<i class="host-mark"></i>), chats_verified_badge(shop)
    assert_equal [shop], seen
    assert_nil chats_verified_badge(@bob), "the override never verifies anyone new"
  end

  test "verified_badge must be callable, and nil restores the default" do
    assert_raises(Chats::ConfigurationError) { Chats.config.verified_badge = "<b>si</b>" }

    Chats.config.verified_badge = ->(_messager) { "x" }
    Chats.config.verified_badge = nil

    assert_includes chats_verified_badge(create_shop), "chats-verified"
  end
end
