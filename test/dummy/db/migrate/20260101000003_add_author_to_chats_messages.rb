# frozen_string_literal: true

# The dummy host mirrors what `rails g chats:upgrade` writes into a real app
# — including the guards. On a FRESH database the create migration above
# already added the author columns, so this one must find them and do
# nothing; on an existing 0.1.x database it adds them. Both paths run for
# real in CI (sqlite reuses a committed database, postgres/mysql start
# empty), which is the point.
class AddAuthorToChatsMessages < ActiveRecord::Migration[7.1]
  def up
    unless column_exists?(:chats_messages, :author_type)
      add_reference :chats_messages, :author, polymorphic: true, null: true,
                                              type: chats_foreign_key_type, index: false
    end

    return if index_exists?(:chats_messages, %i[author_type author_id], name: "index_chats_messages_on_author")

    add_index :chats_messages, %i[author_type author_id], name: "index_chats_messages_on_author"
  end

  def down
    if index_exists?(:chats_messages, %i[author_type author_id], name: "index_chats_messages_on_author")
      remove_index :chats_messages, name: "index_chats_messages_on_author"
    end

    return unless column_exists?(:chats_messages, :author_type)

    remove_column :chats_messages, :author_type
    remove_column :chats_messages, :author_id
  end

  private

  def chats_foreign_key_type
    config = Rails.configuration.generators
    config.options[config.orm][:primary_key_type] || :bigint
  end
end
