# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/chats/install_generator"

class InstallGeneratorTest < Rails::Generators::TestCase
  tests Chats::Generators::InstallGenerator
  destination File.expand_path("../../tmp/generators", __dir__)
  setup :prepare_destination

  test "creates the migration and the initializer" do
    run_generator

    assert_migration "db/migrate/create_chats_tables.rb" do |migration|
      assert_match(/class CreateChatsTables < ActiveRecord::Migration\[\d+\.\d+\]/, migration)

      # The four tables.
      %w[chats_conversations chats_participants chats_messages chats_reactions].each do |table|
        assert_match(/create_table :#{table}, id: primary_key_type/, migration)
      end

      # The adaptive machinery the whole gem ecosystem standardizes on:
      # host-configured primary key type (uuid vs bigint), adapter-aware
      # JSON column type, and MySQL-safe JSON defaults.
      assert_match(/primary_key_type, foreign_key_type = primary_and_foreign_key_types/, migration)
      assert_match(/config\.options\[config\.orm\]\[:primary_key_type\]/, migration)
      # By prefix, not `include?("postgresql")`: PostGIS answers "PostGIS".
      assert_match(%r{return :jsonb if connection\.adapter_name\.match\?\(/\\Apostg/i\)}, migration)
      # Both MySQL spellings: Trilogy is MySQL under a different ADAPTER_NAME,
      # and a pattern that misses it hands that host a default MySQL rejects.
      assert_match(%r{return nil if connection\.adapter_name\.match\?\(/mysql\|trilogy/i\)}, migration)

      # Polymorphic references must carry the adaptive FK type.
      assert_match(/t\.references :messager, polymorphic: true, null: false, type: foreign_key_type/, migration)
      assert_match(/t\.references :sender, polymorphic: true, null: true, type: foreign_key_type/, migration)
      # 0.2.0: a FRESH install already carries the authorship columns, so
      # `chats:upgrade` has nothing to do there.
      assert_match(/t\.references :author, polymorphic: true, null: true, type: foreign_key_type/, migration)
      assert_match(/add_index :chats_messages, \[ :author_type, :author_id \]/, migration)

      # The race-safety backbone: unique indexes. (Omakase array spacing —
      # `[ :a, :b ]` — so installs are rubocop-clean in stock Rails apps.)
      assert_match(/add_index :chats_conversations, :direct_key, unique: true/, migration)
      assert_match(
        /add_index :chats_participants, \[ :conversation_id, :messager_type, :messager_id \],\s+unique: true/,
        migration
      )
    end

    assert_file "config/initializers/chats.rb" do |initializer|
      assert_match(/Chats\.configure do \|config\|/, initializer)
      assert_match(/config\.messager_class = "User"/, initializer)
      assert_match(/blocked_messager_ids/, initializer) # the moderate seam, documented
      assert_match(/Chats\.on\(:message_created\)/, initializer) # the event bus, documented
      assert_match(/config\.messager_url/, initializer)
      assert_match(/config\.inbox_limit/, initializer)
      assert_match(/acts_as_messager notifications: false/, initializer)
    end
  end

  test "running twice doesn't duplicate the migration" do
    run_generator
    run_generator

    migrations = Dir[File.join(destination_root, "db/migrate/*_create_chats_tables.rb")]
    assert_equal 1, migrations.size
  end
end
