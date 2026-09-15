# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/chats/upgrade_generator"

class UpgradeGeneratorTest < Rails::Generators::TestCase
  tests Chats::Generators::UpgradeGenerator
  destination File.expand_path("../../tmp/generators", __dir__)
  setup :prepare_destination

  test "writes the 0.2.0 authorship migration and nothing else" do
    run_generator

    assert_migration "db/migrate/add_author_to_chats_messages.rb" do |migration|
      assert_match(/class AddAuthorToChatsMessages < ActiveRecord::Migration\[\d+\.\d+\]/, migration)

      # Guarded on BOTH sides, so running it against a 0.2.0 fresh install
      # (whose create migration already added the columns) is a no-op.
      assert_match(/unless column_exists\?\(:chats_messages, :author_type\)/, migration)
      assert_match(/add_reference :chats_messages, :author, polymorphic: true, null: true/, migration)
      assert_match(/return if index_exists\?\(:chats_messages, \[ :author_type, :author_id \]/, migration)
      assert_match(/add_index :chats_messages, \[ :author_type, :author_id \], name: "index_chats_messages_on_author"/,
                   migration)

      # uuid/bigint adaptivity, like the install migration.
      assert_match(/config\.options\[config\.orm\]\[:primary_key_type\] \|\| :bigint/, migration)

      # It must reverse cleanly.
      assert_match(/def down/, migration)
      assert_match(/remove_column :chats_messages, :author_type/, migration)
    end

    # An upgrade touches migrations only: the initializer and the views a
    # host already owns are theirs.
    assert_no_file "config/initializers/chats.rb"
  end

  test "running twice doesn't duplicate the migration" do
    run_generator
    run_generator

    migrations = Dir[File.join(destination_root, "db/migrate/*_add_author_to_chats_messages.rb")]
    assert_equal 1, migrations.size
  end
end
