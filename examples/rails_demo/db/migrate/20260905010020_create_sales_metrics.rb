class CreateSalesMetrics < ActiveRecord::Migration[8.1]
  def change
    create_table :sales_metrics do |t|
      t.references :inventory_item, null: false, foreign_key: true
      t.integer :period_days, null: false
      t.integer :units_sold, null: false

      t.timestamps
    end
    add_index :sales_metrics, %i[inventory_item_id period_days], unique: true
  end
end
