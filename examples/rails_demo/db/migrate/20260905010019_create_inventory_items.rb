class CreateInventoryItems < ActiveRecord::Migration[8.1]
  def change
    create_table :inventory_items do |t|
      t.string :sku, null: false
      t.string :name, null: false
      t.string :category, null: false
      t.integer :stock_on_hand, null: false, default: 0
      t.integer :stock_reserved, null: false, default: 0
      t.integer :reorder_point, null: false, default: 0

      t.timestamps
    end
    add_index :inventory_items, :sku, unique: true
  end
end
