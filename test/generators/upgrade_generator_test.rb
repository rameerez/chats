# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/chats/upgrade_generator"

class UpgradeGeneratorTest < Rails::Generators::TestCase
  tests Chats::Generators::UpgradeGenerator
  destination File.expand_path("../../tmp/generators", __dir__)
  setup :prepare_destination

  test "writes the 0.2.0 authorship migration" do
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

  test "writes the 0.4.0 action migration" do
    run_generator

    assert_migration "db/migrate/add_action_to_chats_messages.rb" do |migration|
      assert_match(/class AddActionToChatsMessages < ActiveRecord::Migration\[\d+\.\d+\]/, migration)

      # Guarded, so running it against a 0.4.0 fresh install (whose create
      # migration already has the column) is a no-op.
      assert_match(/return if column_exists\?\(:chats_messages, :action\)/, migration)

      # Adapter-aware JSON, like the install migration — and no default:
      # MySQL refuses defaults on JSON columns, and most messages have none.
      assert_match(%r{return :jsonb if connection\.adapter_name\.match\?\(/\\Apostg/i\)}, migration)
      assert_match(/add_column :chats_messages, :action, json_column_type$/, migration)

      # It must reverse cleanly.
      assert_match(/def down/, migration)
      assert_match(/return unless column_exists\?\(:chats_messages, :action\)/, migration)
      assert_match(/remove_column :chats_messages, :action/, migration)
    end
  end

  test "writes the migrations in version order, and touches nothing else" do
    run_generator

    migrations = Dir[File.join(destination_root, "db/migrate/*.rb")].map { |path| File.basename(path) }.sort
    names = migrations.map { |name| name.sub(/\A\d+_/, "") }
    assert_equal %w[add_author_to_chats_messages.rb add_action_to_chats_messages.rb], names

    # An upgrade touches migrations only: the initializer and the views a
    # host already owns are theirs.
    assert_no_file "config/initializers/chats.rb"
  end

  test "running twice doesn't duplicate the migrations" do
    run_generator
    run_generator

    %w[add_author_to_chats_messages add_action_to_chats_messages].each do |name|
      assert_equal 1, Dir[File.join(destination_root, "db/migrate/*_#{name}.rb")].size, name
    end
  end

  test "the post-upgrade message names what 0.4.0 adds" do
    output = run_generator

    assert_match(/0\.4\.0/, output)
    assert_match(/action: \{ label:/, output)
    assert_match(/_composer_actions\.html\.erb/, output)
  end
end
