# frozen_string_literal: true

require "rails/generators/base"
require "rails/generators/active_record"

module Chats
  module Generators
    # `rails generate chats:upgrade` — copy the migrations a version bump
    # needs into an EXISTING install. Nothing else: the initializer, the
    # views and the routes you already own stay untouched.
    #
    # Currently writes the 0.2.0 migration (message authorship). It is
    # written guarded, so running it against an install that already has the
    # columns (a fresh 0.2.0 install) is a no-op rather than an error.
    class UpgradeGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)
      desc "Add the migrations a chats version bump needs (0.2.0: message authorship)"

      def self.next_migration_number(dir)
        ActiveRecord::Generators::Base.next_migration_number(dir)
      end

      def create_author_migration
        migration_template "add_author_to_chats_messages.rb.erb",
                           File.join(db_migrate_path, "add_author_to_chats_messages.rb")
      end

      def display_post_upgrade_message
        say "\n💬 chats upgrade migrations copied.", :green
        say "\n  1. Run 'rails db:migrate'."
        say "  2. New in 0.2.0 — all opt-in, nothing changes until you ask:"
        say "       acts_as_messager notifications: false, blockable: false, inbox: :grouped"
        say "       Chats.on(:message_created) { |message| … }   # replaces config.notifier"
        say "       config.messager_url / config.message_signature / config.inbox_scope"
        say "       chat_locked? / chat_locked_notice on your chat subjects"
        say "  3. See the CHANGELOG for the full list.\n", :green
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::STRING.to_f}]"
      end
    end
  end
end
