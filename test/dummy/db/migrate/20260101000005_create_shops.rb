# frozen_string_literal: true

# shops  an OFFICIAL account that is otherwise an ORDINARY messager —
#        notifiable, blockable, one inbox row per thread. It exists so the
#        suite proves `verified:` is orthogonal to the headless options
#        rather than a fourth name for "is a desk".
class CreateShops < ActiveRecord::Migration[7.1]
  def change
    create_table :shops do |t|
      t.string :name, null: false
      t.timestamps
    end
  end
end
