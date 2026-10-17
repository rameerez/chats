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

  # Rolling back KEEPS the column, on purpose: this migration never removes
  # a column it may not have added. On a fresh 0.4.0 install the create
  # migration owns `action` and `up` above did nothing, so dropping it here
  # would destroy every message's button with it — and nothing a migration
  # can see records which of the two added it. A leftover nullable column
  # is harmless to older versions of chats; drop it by hand if you mean to.
  def down; end

  private

  def json_column_type
    return :jsonb if connection.adapter_name.match?(/\Apostg/i)

    :json
  end
end
