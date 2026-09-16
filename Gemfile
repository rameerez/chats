# frozen_string_literal: true

source "https://rubygems.org"

# Runtime dependencies are specified in chats.gemspec
gemspec

# Build & release tools
gem "rake", "~> 13.0"

group :development do
  gem "appraisal"
  gem "web-console"

  # Code quality
  gem "rubocop", "~> 1.0", require: false
  gem "rubocop-minitest", "~> 0.35", require: false
  gem "rubocop-performance", "~> 1.0", require: false
end

group :test do
  # json 3.0 dropped `JSON.parse(source, options_hash)`, which is exactly how
  # ActiveSupport::JSON.decode calls it — so every JSON column in the dummy
  # app raises ArgumentError on read, on every adapter. CI resolves fresh and
  # hit this; a local bundle holding an older json did not. Pin until Rails
  # ships a json 3 compatible decoder.
  gem "json", "~> 2.7"

  gem "minitest", "~> 6.0"
  # Minitest 6 extracted minitest/mock into its own gem.
  gem "minitest-mock"
  gem "mocha", "~> 2.0"
  gem "simplecov", require: false

  # Rails frameworks the dummy app boots that are NOT runtime dependencies of
  # the gem itself. The gemspec only depends on what chats actually needs at
  # runtime (activerecord/activesupport/railties/globalid/turbo-rails);
  # ActionCable (the Turbo Streams transport), ActiveStorage (image
  # attachments on messages), ActiveJob (the `broadcast_*_later` jobs), and
  # ActionMailer (hosts often email from the notifier hook; the dummy boots it
  # so the integration is exercised) are pieces the HOST app provides — so
  # they belong in the test bundle, not the gemspec. railties pulls in
  # actionpack/actionview (the engine's controllers + views), but these
  # frameworks are standalone gems Bundler won't install transitively, so the
  # dummy can't `require` their railties without them being declared here.
  gem "actioncable"
  gem "actionmailer"
  gem "activejob"
  gem "activestorage"

  # Database adapters (for multi-database testing)
  gem "mysql2"
  gem "pg"
  gem "sqlite3"

  # Dummy Rails app
  gem "bootsnap", require: false
  gem "importmap-rails"
  gem "propshaft"
  gem "puma"
  gem "stimulus-rails"

  # Fix RDoc version conflict (Ruby 3.4+ ships with 7.0.3)
  gem "rdoc", ">= 7.0"
end
