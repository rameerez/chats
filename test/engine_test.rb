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
      "controllers/chats/refresh_inbox_controller" => "chats/refresh_inbox_controller.js"
    }.each do |name, path|
      pin = packages[name]

      assert pin, "expected #{name} to be pinned (stimulus-loading auto-registration depends on it)"
      assert_equal path, pin.path
    end
  end

  test "serves engine javascript and stylesheets through the host asset pipeline" do
    paths = Rails.application.config.assets.paths.map(&:to_s)

    assert(paths.any? { |path| path.end_with?("chats/app/javascript") })
    assert(paths.any? { |path| path.end_with?("chats/app/assets/stylesheets") })

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
