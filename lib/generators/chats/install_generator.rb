# frozen_string_literal: true

require "rails/generators/base"
require "rails/generators/active_record"

module Chats
  module Generators
    # `rails generate chats:install` — copies the adaptive migration (uuid or
    # bigint keys, adapter-aware JSON columns) and the annotated initializer,
    # then prints the remaining setup steps.
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)
      desc "Install chats migrations and initializer"

      def self.next_migration_number(dir)
        ActiveRecord::Generators::Base.next_migration_number(dir)
      end

      def create_migration_file
        migration_template "create_chats_tables.rb.erb", File.join(db_migrate_path, "create_chats_tables.rb")
      end

      def create_initializer
        template "initializer.rb", "config/initializers/chats.rb"
      end

      def display_post_install_message
        say "\n💬 The `chats` gem has been installed.", :green
        say "\nTo complete the setup:"

        say "  1. Run 'rails db:migrate' to create the chats tables."
        say "     ⚠️  You must run migrations before starting your app!", :yellow

        say "  2. Make your users conversational:"
        say "       class User < ApplicationRecord"
        say "         acts_as_messager"
        say "       end"

        say "  3. Mount the inbox wherever you want it to live:"
        say "       # config/routes.rb"
        say "       mount Chats::Engine => \"/messages\""

        say "  4. (Optional) Attach conversations to your domain:"
        say "       class Ride < ApplicationRecord"
        say "         acts_as_chat_subject"
        say "       end"
        say "       user.chat_with(driver, about: ride)"

        say "\nYou now have real-time DMs: inbox, threads, reactions, read receipts. 🚀"
        say "Pure Hotwire — works out of the box with importmaps + the default Stimulus setup.\n", :green
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::STRING.to_f}]"
      end
    end
  end
end
