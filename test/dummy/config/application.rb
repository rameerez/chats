# frozen_string_literal: true

require_relative "boot"

# Pull in ONLY the Rails frameworks the gem's test suite actually exercises,
# rather than `require "rails/all"`. A leaner boot is faster and makes the
# dependency surface explicit:
#   - active_record     : the chats models + the dummy User/Listing host models
#   - action_cable      : the Turbo Streams transport every broadcast rides on
#   - active_job        : the `broadcast_*_later` jobs + notifier-hook patterns
#   - active_storage    : message image attachments
#   - action_controller : the engine's controllers (inbox/thread/messages)
#   - action_view       : renders the engine views + broadcast partials
#   - action_mailer     : hosts commonly email from the notifier hook; booting
#                         it keeps that integration path honest in tests
# We deliberately SKIP action_mailbox / action_text — nothing in the gem
# touches them, and loading them only slows the suite.
require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_view/railtie"
require "action_mailer/railtie"
require "action_cable/engine"

# The Hotwire pieces a real host has installed. importmap/stimulus/propshaft
# aren't runtime dependencies of the gem (see chats.gemspec) but ARE the
# default Rails 8 front-end — loading them here exercises the engine's
# importmap initializer (the controllers/chats/* pins) and asset-path wiring
# exactly like a real host would.
require "propshaft"
require "turbo-rails"
require "importmap-rails"
require "stimulus-rails"

# Load the gem under test. `Bundler.require` would also work, but requiring
# the entry point explicitly keeps the dummy honest about what it depends on
# and means the engine is loaded the same way a real host loads it.
require "chats"

module Dummy
  # The minimal host application the engine mounts into. Everything here is
  # the smallest config that lets the suite boot across the Rails 7.1 / 7.2 /
  # 8.1 matrix (see .github/workflows/test.yml) and across the
  # sqlite/postgres/mysql database matrix (see config/database.yml).
  class Application < Rails::Application
    # PIN THE APP ROOT EXPLICITLY to this dummy directory (test/dummy), not
    # whatever Rails guesses. Rails infers an application's root by walking up
    # for markers like a Gemfile/Rakefile/config.ru; from `rake test` (run at
    # the GEM root) it would otherwise guess the gem root, so
    # `config/database.yml` would resolve to `<gem>/config/database.yml`
    # (which doesn't exist) instead of `test/dummy/config/database.yml`.
    config.root = File.expand_path("..", __dir__)

    # Pin the framework defaults to the gemspec floor (Rails 7.1). The dummy
    # must boot identically on every Rails in the matrix, so we anchor to the
    # LOWEST supported version's defaults — newer Rails happily loads older
    # defaults, and this avoids a higher default silently enabling behavior
    # 7.1 hosts won't have.
    config.load_defaults 7.1

    # Eager load in test so the whole gem (every model, controller, helper)
    # is loaded up front: it surfaces autoload/NameError problems as a boot
    # failure instead of a mysterious mid-test error.
    config.eager_load = true

    # Quiet, deterministic test output.
    config.consider_all_requests_local = true
    config.action_controller.perform_caching = false
    config.active_support.deprecation = :stderr

    # Don't dump schema.rb after migrating. CI drives the test DB with
    # `db:migrate:reset` (migrations, not schema.rb) precisely because a
    # dumped schema.rb carries SQLite-specific JSON/default quirks that fail
    # to load on PostgreSQL/MySQL. Disabling the dump keeps the migrations
    # the single source of truth for the schema across the DB matrix.
    config.active_record.dump_schema_after_migration = false

    # :test adapters everywhere so the suite can assert on enqueued jobs
    # (`perform_enqueued_jobs` drives the broadcast jobs), captured cable
    # broadcasts, and deliveries without external services.
    config.active_job.queue_adapter = :test
    config.action_mailer.delivery_method = :test
    config.active_storage.service = :test

    # A real cache store (not :null_store) so Rails 8's controller rate_limit
    # (used by Chats::MessagesController) can actually count.
    config.cache_store = :memory_store

    # What config/environments/test.rb sets in a generated app (the dummy has
    # no environment files): without it, every integration-test POST trips
    # CSRF protection and 422s.
    config.action_controller.allow_forgery_protection = false

    config.action_mailer.default_url_options = { host: "example.com" }

    # Secret base for cookies / signed GlobalIDs (the chat_button_to sgids).
    # A fixed value keeps signed tokens stable within a run.
    config.secret_key_base = "chats_dummy_secret_key_base_for_tests_only"
  end
end
