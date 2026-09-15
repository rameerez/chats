# frozen_string_literal: true

require "test_helper"

# The README and the generated initializer are executable promises. These
# assertions are cheap and catch the two ways doc snippets rot: code that
# would raise where it is shown, and a documented contract drifting from the
# one the gem implements.
class DocsTest < ActiveSupport::TestCase
  README = File.expand_path("../README.md", __dir__)
  INITIALIZER = File.expand_path("../lib/generators/chats/templates/initializer.rb", __dir__)

  test "the messager_url snippets resolve routes the way a host actually can" do
    [README, INITIALIZER].each do |path|
      source = File.read(path)

      assert_includes source, "Rails.application.routes.url_helpers",
                      "#{File.basename(path)} must not imply url helpers are available on the initializer"
      assert_no_match(/config\.messager_url = ->\(messager\) \{ messager\.is_a\?/, source,
                      "#{File.basename(path)} still shows the raising is_a? one-liner")
    end
  end

  test "the README's messager_url snippet runs and returns a path" do
    alice = create_user(name: "Alice")
    desk = create_desk(name: "Support")

    # The exact lambda the README shows, with the host's own class check —
    # the one place that check legitimately lives.
    messager_url = lambda do |messager|
      routes = Rails.application.routes.url_helpers

      case messager
      when User then routes.test_login_path(messager) # a stand-in route the dummy has
      end
    end
    Chats.config.messager_url = messager_url

    assert_equal "/test_login.#{alice.id}", Chats.messager_url_for(alice)
    assert_nil Chats.messager_url_for(desk), "a headless messager has no profile"
  end

  test "the docs name exactly the events config.notifier still receives" do
    legacy = Chats::Subscribers::LEGACY_NOTIFIER_EVENTS

    assert_equal %i[message_created conversation_read], legacy
    legacy.each do |event|
      assert_includes File.read(README), ":#{event}",
                      "the README must name the events the deprecated hook still gets"
    end
  end
end
