# frozen_string_literal: true

require_relative "lib/chats/version"

Gem::Specification.new do |spec|
  spec.name = "chats"
  spec.version = Chats::VERSION
  spec.authors = ["rameerez"]
  spec.email = ["rubygems@rameerez.com"]

  spec.summary = "Add chat messaging (user-to-user DMs & group chats) to your Rails app"
  spec.description = "chats is a drop-in gem to add chat messaging to your Rails app. It implements a real-time messaging engine for Ruby on Rails 8+ apps: direct messages (DMs), group chats, image attachments, emoji reactions, read receipts, unread badges, and typing indicators. All rendered server-side and updated live with Hotwire (Turbo Streams over Action Cable), so it ships with zero custom JavaScript build steps and works with importmaps out of the box. Any model can converse via a single `acts_as_messager` macro (users, organizations, support agents — participants are polymorphic), conversations can be optionally attached to any domain record via `acts_as_chat_subject` (so users can chat about a specific order, a listing, a booking), and the whole inbox UI is overridable view-by-view like Devise. It exposes small adapter seams a blocked-users lookup, a `can_message` policy, and a notifier hook; so it snaps onto the `moderate` gem for Trust & Safety (report/block/filter, DSA + app-store compliance) and onto any notification system (like the `noticed` gem) without any hard dependencies. Messages support soft deletion, editing, system messages posted by your app, per-sender rate limiting, and optional encryption at rest."
  spec.homepage = "https://github.com/rameerez/chats"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["documentation_uri"] = "#{spec.homepage}#readme"
  spec.metadata["rubygems_mfa_required"] = "true"

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Runtime dependencies — kept minimal and host-agnostic on purpose.
  # turbo-rails is the one non-negotiable: the live layer (message broadcasts,
  # inbox refreshes, typing indicators) is Turbo Streams over Action Cable, and
  # the views use `turbo_stream_from`/`turbo_frame_tag`. Everything else
  # (moderation, notifications, pagination, image processing) is an optional
  # host-side integration wired through hooks, never a forced dependency.
  spec.add_dependency "activerecord", ">= 7.1.0", "< 9.0"
  spec.add_dependency "activesupport", ">= 7.1.0", "< 9.0"
  spec.add_dependency "globalid", "~> 1.0"
  spec.add_dependency "railties", ">= 7.1.0", "< 9.0"
  spec.add_dependency "turbo-rails", ">= 2.0"
end
