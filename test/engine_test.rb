# frozen_string_literal: true

require "test_helper"

# The engine's host-integration plumbing: importmap pins, asset paths,
# locales, macros, migration paths.
class EngineTest < ActiveSupport::TestCase
  test "pins its Stimulus controllers under controllers/chats for auto-registration" do
    packages = Rails.application.importmap.packages

    {
      "controllers/chats/thread_controller" => "chats/thread_controller.js",
      "controllers/chats/composer_controller" => "chats/composer_controller.js",
      "controllers/chats/debounced_submit_controller" => "chats/debounced_submit_controller.js",
      "controllers/chats/refresh_inbox_controller" => "chats/refresh_inbox_controller.js",
      "controllers/chats/dock_controller" => "chats/dock_controller.js",
      "controllers/chats/unread_badge_controller" => "chats/unread_badge_controller.js",
      "controllers/chats/split_controller" => "chats/split_controller.js",
      "controllers/chats/tray_controller" => "chats/tray_controller.js"
    }.each do |name, path|
      pin = packages[name]

      assert pin, "expected #{name} to be pinned (stimulus-loading auto-registration depends on it)"
      assert_equal path, pin.path
    end
  end

  test "pins the module its controllers share outside controllers/, where the eager loader never registers it" do
    pin = Rails.application.importmap.packages["chats/recovery"]

    assert pin, "the inbox, thread, badge and dock controllers import chats/recovery"
    assert_equal "chats/recovery.js", pin.path
    assert_empty Rails.application.importmap.packages.keys.grep(%r{\Acontrollers/.*recovery})

    %w[thread_controller refresh_inbox_controller unread_badge_controller dock_controller
       tray_controller].each do |controller|
      source = File.read(Chats::Engine.root.join("app/javascript/chats/#{controller}.js"))
      assert_match(/^import \{ [^}]+ \} from "chats\/recovery"$/, source, controller)
    end
  end

  test "pins the sheet the dock and the tray share outside controllers/ too" do
    pin = Rails.application.importmap.packages["chats/sheet"]

    assert pin, "the dock's sheet and the tray's hold the page's inert through chats/sheet"
    assert_equal "chats/sheet.js", pin.path
    %w[dock_controller tray_controller].each do |controller|
      source = File.read(Chats::Engine.root.join("app/javascript/chats/#{controller}.js"))
      assert_match(/^import \{ [^}]+ \} from "chats\/sheet"$/, source, controller)
    end
  end

  test "serves engine javascript and stylesheets through the host asset pipeline" do
    paths = Rails.application.config.assets.paths.map(&:to_s)

    # The engine's own directories, wherever the gem is checked out (a
    # worktree need not be named "chats").
    assert_includes paths, Chats::Engine.root.join("app/javascript").to_s
    assert_includes paths, Chats::Engine.root.join("app/assets/stylesheets").to_s

    assert File.exist?(Chats::Engine.root.join("app/javascript/chats/thread_controller.js"))
    assert File.exist?(Chats::Engine.root.join("app/assets/stylesheets/chats.css"))
  end

  test "ships en and es locales" do
    assert_equal "Mensajes", I18n.t("chats.inbox.title", locale: :es)
    assert_equal "Messages", I18n.t("chats.inbox.title", locale: :en)
    assert_equal "Visto", I18n.t("chats.thread.seen", locale: :es)
  end

  test "extends ActiveRecord with the macros" do
    assert User.respond_to?(:acts_as_messager)
    assert Listing.respond_to?(:acts_as_chat_subject)
    assert User.include?(Chats::Messager)
    assert Listing.include?(Chats::ChatSubject)
  end

  test "exposes its migrations to the host" do
    assert_includes Rails.application.config.paths["db/migrate"].expanded.map(&:to_s),
                    Chats::Engine.root.join("db/migrate").to_s
  end
end
