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

  # --- 0.4.0: the action column ------------------------------------------------

  test "writes the 0.4.0 action migration where the schema lacks the column" do
    with_action_column(false) { run_generator }

    assert_migration "db/migrate/add_action_to_chats_messages.rb" do |migration|
      assert_match(/class AddActionToChatsMessages < ActiveRecord::Migration\[\d+\.\d+\]/, migration)

      # Guarded, so running it where the column already exists is a no-op.
      assert_match(/return if column_exists\?\(:chats_messages, :action\)/, migration)

      # Adapter-aware JSON, like the install migration — and no default:
      # MySQL refuses defaults on JSON columns, and most messages have none.
      assert_match(%r{return :jsonb if connection\.adapter_name\.match\?\(/\\Apostg/i\)}, migration)
      assert_match(/add_column :chats_messages, :action, json_column_type$/, migration)

      # Rollback never drops a column this migration may not have added.
      assert_match(/def down; end/, migration)
      assert_no_match(/remove_column/, migration)
    end
  end

  test "does not write the action migration where the schema already has the column" do
    # The dummy's own database is a fresh 0.4.0 install: its create
    # migration added the column. Asked for real, not stubbed.
    output = run_generator

    assert_no_migration "db/migrate/add_action_to_chats_messages.rb"
    assert_migration "db/migrate/add_author_to_chats_messages.rb"
    assert_match(/skip.*chats_messages\.action already exists/, output)
  end

  test "writes the action migration when there is no database to ask" do
    ActiveRecord::Base.connection_pool.stub(:with_connection, ->(*) { raise ActiveRecord::ConnectionNotEstablished }) do
      run_generator
    end

    assert_migration "db/migrate/add_action_to_chats_messages.rb"
  end

  test "the action migration adds the column, is idempotent, and its rollback keeps the column and its data" do
    with_action_column(false) { run_generator }

    with_scratch_database do |connection|
      connection.create_table(:chats_messages) { |table| table.text :body }
      migration = generated_action_migration

      migration.exec_migration(connection, :up)
      assert connection.column_exists?(:chats_messages, :action)
      migration.exec_migration(connection, :up) # again: guarded, no error

      connection.execute(%(INSERT INTO chats_messages (body, action) VALUES ('hi', '{"label":"Pay","url":"/pay"}')))
      migration.exec_migration(connection, :down)

      assert connection.column_exists?(:chats_messages, :action), "rollback keeps the column"
      assert_equal '{"label":"Pay","url":"/pay"}', connection.select_value("SELECT action FROM chats_messages")
    end
  end

  test "on a schema whose create migration owns the column, up and down both leave it alone" do
    with_action_column(false) { run_generator }

    with_scratch_database do |connection|
      connection.create_table(:chats_messages) do |table|
        table.text :body
        table.json :action
      end
      connection.execute(%(INSERT INTO chats_messages (body, action) VALUES ('hi', '{"label":"Pay","url":"/pay"}')))
      migration = generated_action_migration

      migration.exec_migration(connection, :up)
      migration.exec_migration(connection, :down)

      assert connection.column_exists?(:chats_messages, :action), "a column it didn't add is never dropped"
      assert_equal '{"label":"Pay","url":"/pay"}', connection.select_value("SELECT action FROM chats_messages")
    end
  end

  test "writes the migrations in version order, and touches nothing else" do
    with_action_column(false) { run_generator }

    migrations = Dir[File.join(destination_root, "db/migrate/*.rb")].map { |path| File.basename(path) }.sort
    names = migrations.map { |name| name.sub(/\A\d+_/, "") }
    assert_equal %w[add_author_to_chats_messages.rb add_action_to_chats_messages.rb], names

    # An upgrade touches migrations only: the initializer and the views a
    # host already owns are theirs.
    assert_no_file "config/initializers/chats.rb"
  end

  test "running twice doesn't duplicate the migrations" do
    with_action_column(false) do
      run_generator
      run_generator
    end

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

  # A throwaway in-memory database, so a migration can run up and down for
  # real without touching the suite's own schema.
  class ScratchDatabase < ActiveRecord::Base
    self.abstract_class = true
  end

  private

  def with_scratch_database(&)
    ScratchDatabase.establish_connection(adapter: "sqlite3", database: ":memory:")
    ScratchDatabase.connection_pool.with_connection(&)
  ensure
    ScratchDatabase.remove_connection
  end

  # The generator asks the schema whether chats_messages.action exists; this
  # answers for it. (The suite's real database has the column.)
  def with_action_column(present, &)
    schema = Object.new
    schema.define_singleton_method(:column_exists?) do |table, column|
      [table, column] == %i[chats_messages action] && present
    end
    ActiveRecord::Base.connection_pool.stub(:with_connection, ->(*, &block) { block.call(schema) }, &)
  end

  # The migration the generator wrote, loaded into its own namespace so it
  # can't collide with the dummy app's migration of the same name.
  def generated_action_migration
    path = Dir[File.join(destination_root, "db/migrate/*_add_action_to_chats_messages.rb")].first
    namespace = Module.new
    namespace.module_eval(File.read(path), path)
    namespace::AddActionToChatsMessages.new
  end
end
