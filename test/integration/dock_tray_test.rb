# frozen_string_literal: true

require "test_helper"

# The tray (0.7.0): what a host puts in `chats_dock { … }` — another surface's
# launcher (support_desk's "Need help?") beside the dock's bar — and the same
# tray on its own (`chats_tray`), through the full request cycle. The dummy's
# `dock_tray` cookie renders a host launcher (layouts/_help_item) in the
# block, its value being that launcher's badge.
class DockTrayTest < ActionDispatch::IntegrationTest
  setup do
    @alice = create_user(name: "Alice")
    @bob = create_user(name: "Bob")
  end

  test "a dock with no block is the dock it always was: no tray" do
    login_as @alice

    get "/"

    assert_select "aside.chats-dock" do
      assert_empty css_select(".chats-tray")
      assert_empty css_select(".chats-tray__item")
    end
  end

  test "the block's items sit in the dock's tray, between the windows and the panel" do
    login_as @alice
    cookies[:dock_tray] = "2"

    get "/"

    assert_select "aside.chats-dock[data-controller='chats--dock']" do |dock|
      action = dock.first["data-action"]
      assert_includes action, "chats--tray:open->chats--dock#trayOpened", "an item opening closes the panel"
      order = dock.first.element_children.map { |child| child["class"].to_s.split.first || child.name }
      assert_operator order.index("chats-dock__windows"), :<, order.index("chats-tray")
      assert_operator order.index("chats-tray"), :<, order.index("chats-dock__panel")
    end
    tray = css_select(".chats-dock > .chats-tray").first
    assert_equal "chats--tray", tray["data-controller"]
    assert_equal "tray", tray["data-chats--dock-target"], "the dock measures it for the windows' room"
    assert_equal Chats.messager_key(@alice), tray["data-chats--tray-owner-value"], "remembered per viewer"
    assert_equal "false", tray["data-chats--tray-standalone-value"], "the dock hides it and fits the viewport"
  end

  test "an item: a details with the read gate, its tab, its title, its badge and its panel" do
    login_as @alice
    cookies[:dock_tray] = "2"

    get "/"

    assert_select "details#chats_tray_help.chats-tray__item:not([open])" do |items|
      item = items.first
      assert_equal "item", item["data-chats--tray-target"]
      assert_equal "help", item["data-chats-tray-key"]
      assert_equal "true", item["data-chats-active"], "the gate chats' thread controller obeys"
      assert item.key?("data-chats-minimized"), "closed: nothing inside reads"
      assert_equal "toggle->chats--tray#toggled", item["data-action"]

      assert_select "summary.chats-tray__launcher" do
        assert_select ".chats-tray__icon[aria-hidden='true'] svg"
        assert_select ".chats-tray__label", text: "Need help?"
        assert_select ".chats-tray__title", text: "Help centre"
        assert_select "#dummy_help_badge.chats-badge.chats-tray__badge[data-chats--tray-target='badge']" \
                      "[data-count='2']", text: /2 unread/

        assert_select ".chats-tray__chevron[aria-hidden='true']"
        assert_select ".chats-tray__close-glyph[aria-hidden='true']"
      end
      assert_empty item.css(".chats-dock__bar, .chats-dock__title"),
                   "its own classes: a host's selectors for the dock's bar still find one"

      assert_select ".chats-tray__body[role='region'][aria-label='Help centre'] .dummy-help[data-chats-tray-refresh]"
    end
  end

  test "a badge at zero is hidden, its number kept" do
    login_as @alice
    cookies[:dock_tray] = "0"

    get "/"

    assert_select "#dummy_help_badge[hidden][data-count='0']"
  end

  test "signed out there is no dock, but the tray stands on its own in the corner" do
    cookies[:dock_tray] = "0"

    get "/"

    assert_empty css_select("aside.chats-dock"), "no messaging without a viewer"
    assert_select "div#chats_tray_guest.chats-dock.chats-dock--tray-only[data-turbo-permanent]" do
      assert_select "> .chats-tray[data-controller='chats--tray'][data-chats--tray-standalone-value='true']" \
                    "[data-chats--tray-owner-value='guest']" do
        assert_select "details#chats_tray_help"
      end
      assert_empty css_select("[data-chats--dock-target]"), "no dock controller to answer to"
    end
    assert_select "link[rel='stylesheet'][href*='chats']", minimum: 1
  end

  test "signed out with nothing in the block: nothing at all" do
    get "/"

    assert_empty css_select(".chats-dock")
  end

  test "launcher: false reaches the tray's round buttons too" do
    cookies[:dock_tray] = "0"
    get "/", params: { dock_launcher: "0" }

    assert_select ".chats-dock--tray-only.chats-dock--no-launcher"
  end

  test "on the engine's own pages there is no dock, tray included" do
    conversation_between(@alice, @bob)
    @bob.message!(Chats::Conversation.direct_between(@alice, @bob), "hola")
    login_as @alice
    cookies[:dock_tray] = "1"

    get "/messages"

    assert_response :success
    assert_empty css_select(".chats-dock")
    assert_empty css_select(".chats-tray")
  end
end
