# frozen_string_literal: true

# The dummy host mirrors what `rails g chats:upgrade` writes for 0.4.0 —
# guards included. On a FRESH database the create migration already added
# the column, so this one must find it and do nothing; on a database
# migrated before 0.4.0 (a reused local sqlite file) it adds it. Both paths
# are the ones real hosts take.
class AddActionToChatsMessages < ActiveRecord::Migration[7.1]
  def up
    return if column_exists?(:chats_messages, :action)

    add_column :chats_messages, :action, json_column_type
  end

  def down
    return unless column_exists?(:chats_messages, :action)

    remove_column :chats_messages, :action
  end

  private

  def json_column_type
    return :jsonb if connection.adapter_name.match?(/\Apostg/i)

    :json
  end
end
