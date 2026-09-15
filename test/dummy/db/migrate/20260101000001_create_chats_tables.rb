# frozen_string_literal: true

# A migrated COPY of the gem's adaptive migration template
# (lib/generators/chats/templates/create_chats_tables.rb.erb) with the ERB
# version pinned — keep the two IN SYNC when the schema evolves. The dummy
# host uses default bigint keys; the template's adaptive helpers
# (primary_and_foreign_key_types / json_column_type / json_column_default)
# are kept verbatim so the very code paths hosts run are the ones tested,
# including the uuid branch via the generators-config stub in
# test/generators/install_generator_test.rb.
class CreateChatsTables < ActiveRecord::Migration[7.1]
  def change
    primary_key_type, foreign_key_type = primary_and_foreign_key_types

    create_table :chats_conversations, id: primary_key_type do |t|
      t.string :kind, null: false, default: "direct"
      t.string :title
      t.references :subject, polymorphic: true, type: foreign_key_type, null: true, index: false
      t.string :direct_key
      t.datetime :last_message_at
      t.column :last_message_id, foreign_key_type
      t.integer :messages_count, null: false, default: 0

      t.timestamps
    end

    add_index :chats_conversations, %i[subject_type subject_id], name: "index_chats_conversations_on_subject"
    add_index :chats_conversations, :direct_key, unique: true, name: "index_chats_conversations_on_direct_key"
    add_index :chats_conversations, :last_message_at, name: "index_chats_conversations_on_last_message_at"

    create_table :chats_participants, id: primary_key_type do |t|
      t.references :conversation, null: false, type: foreign_key_type,
                                  foreign_key: { to_table: :chats_conversations }, index: false
      t.references :messager, polymorphic: true, null: false, type: foreign_key_type, index: false

      t.string :role, null: false, default: "member"
      t.datetime :last_read_at
      t.datetime :muted_at
      t.datetime :left_at
      t.datetime :last_notified_at

      t.timestamps
    end

    add_index :chats_participants, %i[conversation_id messager_type messager_id],
              unique: true, name: "index_chats_participants_uniqueness"
    add_index :chats_participants, %i[messager_type messager_id], name: "index_chats_participants_on_messager"

    create_table :chats_messages, id: primary_key_type do |t|
      t.references :conversation, null: false, type: foreign_key_type,
                                  foreign_key: { to_table: :chats_conversations }, index: false
      t.references :sender, polymorphic: true, null: true, type: foreign_key_type, index: false
      t.references :author, polymorphic: true, null: true, type: foreign_key_type, index: false

      t.string :kind, null: false, default: "text"
      t.text :body
      t.references :reply_to, type: foreign_key_type, null: true,
                              foreign_key: { to_table: :chats_messages }, index: false
      t.datetime :edited_at
      t.datetime :deleted_at
      t.send(json_column_type, :metadata, default: json_column_default)

      t.timestamps
    end

    add_index :chats_messages, %i[conversation_id created_at id],
              name: "index_chats_messages_on_conversation_and_created_at"
    add_index :chats_messages, %i[sender_type sender_id], name: "index_chats_messages_on_sender"
    add_index :chats_messages, %i[author_type author_id], name: "index_chats_messages_on_author"
    add_index :chats_messages, :reply_to_id, name: "index_chats_messages_on_reply_to_id"

    create_table :chats_reactions, id: primary_key_type do |t|
      t.references :message, null: false, type: foreign_key_type,
                             foreign_key: { to_table: :chats_messages }, index: false
      t.references :reactor, polymorphic: true, null: false, type: foreign_key_type, index: false
      t.string :emoji, null: false

      t.timestamps
    end

    add_index :chats_reactions, %i[message_id reactor_type reactor_id emoji],
              unique: true, name: "index_chats_reactions_uniqueness"
  end

  private

  def primary_and_foreign_key_types
    config = Rails.configuration.generators
    setting = config.options[config.orm][:primary_key_type]
    primary_key_type = setting || :primary_key
    foreign_key_type = setting || :bigint
    [primary_key_type, foreign_key_type]
  end

  def json_column_type
    return :jsonb if connection.adapter_name.downcase.include?("postgresql")

    :json
  end

  def json_column_default
    return nil if connection.adapter_name.downcase.include?("mysql")

    {}
  end
end
