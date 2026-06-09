# frozen_string_literal: true

class CreateDummyHostTables < ActiveRecord::Migration[7.1]
  def change
    create_table :users do |t|
      t.string :name, null: false
      t.string :email
      t.timestamps
    end

    create_table :listings do |t|
      t.string :title, null: false
      t.timestamps
    end
  end
end
