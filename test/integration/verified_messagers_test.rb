# frozen_string_literal: true

require "test_helper"

# `acts_as_messager verified: true` — the official-account badge, through the
# full request cycle. Three surfaces show a messager's name and all three must
# mark it: the ordinary inbox row, the stacked inbox row, and the thread
# header. A badge that appears in two of them is worse than none, because the
# absence then reads as "this one isn't official".
class VerifiedMessagersTest < ActionDispatch::IntegrationTest
  BADGE = "span.chats-verified"

  setup do
    @alice = create_user(name: "Alice")
    @bob = create_user(name: "Bob")
    @shop = create_shop(name: "Tienda Oficial") # verified, ordinary inbox row
    @desk = create_desk(name: "Soporte")        # verified AND stacked
  end

  # --- the three surfaces -----------------------------------------------------

  test "an ordinary inbox row badges an official counterpart" do
    @alice.chat_with(@shop)
    login_as @alice

    get "/messages"

    assert_response :success
    row = css_select("li.chats-row").first
    assert_includes row.text, "Tienda Oficial"
    assert_equal 1, row.css(BADGE).size
  end

  test "a stacked inbox row badges an official counterpart" do
    2.times { |i| @alice.chat_with(@desk, about: create_listing(title: "L#{i}")) }
    login_as @alice

    get "/messages"

    assert_response :success
    row = css_select("li.chats-row--group").first
    assert_includes row.text, "Soporte"
    assert_equal 1, row.css(BADGE).size
  end

  test "the thread header badges an official counterpart" do
    conversation = @alice.chat_with(@shop)
    login_as @alice

    get "/messages/#{conversation.id}"

    assert_response :success
    title = css_select(".chats-thread__title").first
    assert_includes title.text, "Tienda Oficial"
    assert_equal 1, title.css(BADGE).size
  end

  test "the badge sits NEXT TO the name, never in place of it" do
    conversation = @alice.chat_with(@shop)
    login_as @alice

    get "/messages/#{conversation.id}"

    name = css_select(".chats-thread__title .chats-thread__name").first
    assert_equal "Tienda Oficial", name.text.strip
    assert_empty name.css(BADGE), "the badge must not live inside the ellipsizing name"
  end

  # --- and nowhere else -------------------------------------------------------

  test "an ordinary messager is never badged, in the inbox or in the thread" do
    conversation = @alice.chat_with(@bob)
    login_as @alice

    get "/messages"
    assert_empty css_select(BADGE), "a plain acts_as_messager must render exactly what 0.2.0 rendered"

    get "/messages/#{conversation.id}"
    assert_empty css_select(BADGE)
    assert_equal "Bob", css_select(".chats-thread__title").first.text.strip
  end

  test "a stacked counterpart that is NOT official gets no badge" do
    Desk.stubs(:chat_verified?).returns(false)
    2.times { |i| @alice.chat_with(@desk, about: create_listing(title: "L#{i}")) }
    login_as @alice

    get "/messages"

    assert_equal 1, css_select("li.chats-row--group").size
    assert_empty css_select(BADGE), "stacking and verification are separate options"
  end

  test "a group conversation is never badged by one official member" do
    group = @alice.chat_with(@bob, @shop, title: "Pedido 4221")
    login_as @alice

    get "/messages"
    assert_empty css_select(BADGE), "a group is named after itself, not after any one member"

    get "/messages/#{group.id}"
    assert_empty css_select(".chats-thread__title #{BADGE}")
  end

  # --- accessibility & i18n ---------------------------------------------------

  test "the badge is announced as an official account, not as decoration" do
    @alice.chat_with(@shop)
    login_as @alice

    get "/messages"

    badge = css_select(BADGE).first
    assert_equal "img", badge["role"]
    assert_equal "Official account", badge["aria-label"]
    assert_equal "Official account", badge["title"]
    assert_equal "true", badge.css("svg").first["aria-hidden"],
                 "the glyph must not be announced a second time"
  end

  test "the label is translated in both bundled locales" do
    assert_equal "Official account", I18n.t("chats.verified.label", locale: :en)
    assert_equal "Cuenta oficial", I18n.t("chats.verified.label", locale: :es)
  end

  # --- the host's escape hatch ------------------------------------------------

  test "config.verified_badge replaces the glyph everywhere it renders" do
    Chats.config.verified_badge = lambda do |messager|
      ActionController::Base.helpers.tag.b("OFICIAL #{messager.name}", class: "my-badge")
    end
    @alice.chat_with(@shop)
    login_as @alice

    get "/messages"

    assert_empty css_select(BADGE), "the gem's rosette steps aside for the host's mark"
    assert_equal "OFICIAL Tienda Oficial", css_select("b.my-badge").first.text
  end

  test "a host badge that returns nil renders nothing at all" do
    Chats.config.verified_badge = ->(_messager) { nil }
    @alice.chat_with(@shop)
    login_as @alice

    get "/messages"

    assert_response :success
    assert_empty css_select(BADGE)
    assert_includes response.body, "Tienda Oficial"
  end
end
