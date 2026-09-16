# frozen_string_literal: true

# SimpleCov must be loaded before any application code
# (configuration is auto-loaded from the .simplecov file).
require "simplecov"

# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

require File.expand_path("dummy/config/environment.rb", __dir__)
ActiveRecord::Migrator.migrations_paths = [
  File.expand_path("dummy/db/migrate", __dir__)
]

# Auto-migrate so a plain `bundle exec rake test` works on a fresh checkout
# (CI also runs db:migrate explicitly; this is idempotent either way).
ActiveRecord::MigrationContext.new(ActiveRecord::Migrator.migrations_paths).migrate

require "rails/test_help"
require "minitest/mock"
require "mocha/minitest"

# Filter out Minitest backtrace while allowing backtrace from other libraries
# to be shown.
Minitest.backtrace_filter = Minitest::BacktraceFilter.new

module ActiveSupport
  class TestCase
    include ActiveJob::TestHelper
    include Turbo::Broadcastable::TestHelper

    setup do
      # Start every test from a known configuration so hooks/policies/flags
      # never leak between tests — and re-register the dummy host classes the
      # reset wiped (registries are global state too).
      Chats.reset!
      Chats.configure { |config| config.messager_class = "User" }
      Chats.register_messager(User)
      Chats.register_messager(Desk)
      Chats.register_messager(Shop)
      Chats.register_chat_subject(Listing)
      # The gem's own deprecator would otherwise print on every test that
      # exercises the deprecated `config.notifier`. `assert_deprecated`
      # swaps the behavior itself, so assertions still work.
      Chats.deprecator.behavior = :silence
    end

    teardown do
      Chats.reset!
    end

    # --- Data helpers -----------------------------------------------------------

    def create_user(name: "User #{SecureRandom.hex(3)}", **attributes)
      User.create!(name: name, **attributes)
    end

    def create_listing(title: "Madrid → Barcelona", **attributes)
      Listing.create!(title: title, **attributes)
    end

    # The headless messager (no notifications, not blockable, stacked inbox).
    def create_desk(name: "Support", **attributes)
      Desk.create!(name: name, **attributes)
    end

    # An OFFICIAL account that is otherwise an ordinary messager: verified,
    # but notifiable, blockable and one inbox row per thread.
    def create_shop(name: "Tienda Oficial", **attributes)
      Shop.create!(name: name, **attributes)
    end

    # Every SQL statement ActiveRecord runs while the block runs.
    #
    # NOT `assert_no_queries` / `assert_queries_count`: those became public
    # test API in Rails 7.2, and this gem's floor is 7.1 (see the gemspec and
    # the rails-7.1 appraisal), where calling them is a NoMethodError. The
    # notification is the one thing every supported version fires, so an
    # assertion built on it means the same on all of them.
    #
    # SCHEMA and TRANSACTION statements are left out: they are the adapter
    # talking to itself (column lookups, savepoints), they differ between
    # SQLite and PostgreSQL, and they depend on whether the schema cache is
    # already warm — none of which is ever the thing under test.
    def capture_sql(&block)
      statements = []
      counter = lambda do |_name, _start, _finish, _id, payload|
        next if %w[SCHEMA TRANSACTION].include?(payload[:name].to_s)

        statements << payload[:sql]
      end

      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      statements
    end

    # Collect every subscriber payload fired for +event+ while the block runs.
    def capture_chats_events(event)
      fired = []
      Chats.on(event) { |*args, **kwargs| fired << (kwargs.presence || args.first) }
      yield
      fired
    end

    # A direct conversation with both seats taken — the canonical fixture.
    def conversation_between(a, b, about: nil)
      Chats::Conversation.direct_between!(a, b, about: about)
    end

    # Configure blocking the way a real moderate-wired host would: a proc
    # returning ids blocked with the given messager (bidirectional contract).
    def block_pair!(a, b)
      blocked = { a.id => [b.id], b.id => [a.id] }
      Chats.config.blocked_messager_ids = ->(messager) { blocked.fetch(messager.id, []) }
    end

    # An UploadedFile for attachment tests. A 1×1 PNG, tiny and a real image.
    PNG_BYTES = [
      137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1,
      0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84,
      120, 156, 99, 250, 207, 192, 240, 31, 0, 5, 5, 2, 0, 95, 25, 233, 174, 0,
      0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130
    ].pack("C*").freeze

    def png_upload(filename: "photo.png")
      Rack::Test::UploadedFile.new(StringIO.new(PNG_BYTES), "image/png", original_filename: filename)
    end

    def text_upload(filename: "notes.txt")
      Rack::Test::UploadedFile.new(StringIO.new("just text"), "text/plain", original_filename: filename)
    end
  end
end

module ActionDispatch
  class IntegrationTest
    # Act as +messager+ for subsequent requests (any acts_as_messager
    # model — a User, a Desk — see the dummy SessionsController).
    def login_as(messager)
      post "/test_login", params: { messager_gid: messager.to_global_id.to_s }
      assert_response :no_content
    end
  end
end
