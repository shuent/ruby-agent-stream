class CreateSupplierTerms < ActiveRecord::Migration[8.1]
  def change
    create_table :supplier_terms do |t|
      t.references :inventory_item, null: false, foreign_key: true, index: { unique: true }
      t.string :supplier_name, null: false
      t.integer :lead_time_days, null: false
      t.integer :min_order_quantity, null: false
      t.decimal :unit_cost, precision: 10, scale: 2, null: false
      t.integer :pack_size, null: false

      t.timestamps
    end
  end
end
