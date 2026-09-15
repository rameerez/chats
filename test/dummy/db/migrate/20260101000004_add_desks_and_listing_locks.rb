# frozen_string_literal: true

# Host-side fixtures for the 0.2.0 seams:
#   desks           a HEADLESS messager (no notifications, not blockable,
#                   stacked inbox) — the shape support_desk's Desk has
#   listings.locked a LOCKABLE chat subject (chat_locked? / _notice)
class AddDesksAndListingLocks < ActiveRecord::Migration[7.1]
  def change
    create_table :desks do |t|
      t.string :name, null: false
      t.timestamps
    end

    add_column :listings, :locked, :boolean, null: false, default: false
  end
end
