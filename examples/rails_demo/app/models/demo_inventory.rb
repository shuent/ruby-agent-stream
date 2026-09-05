class DemoInventory
  ROWS = [
    { sku: "MUG-RED", name: "波佐見焼マグ 赤", category: "食器", stock_on_hand: 18, stock_reserved: 6, reorder_point: 16,
      sales: 42, supplier: "長崎クラフト商会", lead: 9, minimum: 24, cost: 1_280, pack: 6 },
    { sku: "TWL-LIN", name: "リネンキッチンタオル", category: "キッチン", stock_on_hand: 36, stock_reserved: 8, reorder_point: 20,
      sales: 28, supplier: "瀬戸内リネン", lead: 6, minimum: 20, cost: 620, pack: 10 },
    { sku: "TEA-GRN", name: "知覧茶ティーバッグ", category: "食品", stock_on_hand: 14, stock_reserved: 5, reorder_point: 18,
      sales: 63, supplier: "南九州茶業", lead: 12, minimum: 30, cost: 760, pack: 10 },
    { sku: "BAG-NVY", name: "帆布ミニトート 紺", category: "バッグ", stock_on_hand: 44, stock_reserved: 4, reorder_point: 15,
      sales: 12, supplier: "倉敷帆布パートナーズ", lead: 18, minimum: 12, cost: 2_450, pack: 4 }
  ].freeze

  def self.reset!
    InventoryItem.transaction do
      ReplenishmentOrder.delete_all
      InventoryItem.destroy_all
      ROWS.each do |row|
        item = InventoryItem.create!(row.slice(:sku, :name, :category, :stock_on_hand, :stock_reserved, :reorder_point))
        item.sales_metrics.create!(period_days: 30, units_sold: row.fetch(:sales))
        item.create_supplier_term!(supplier_name: row.fetch(:supplier), lead_time_days: row.fetch(:lead),
                                   min_order_quantity: row.fetch(:minimum), unit_cost: row.fetch(:cost), pack_size: row.fetch(:pack))
      end
      DemoRevision.invalidate!
    end
    InventoryCatalog.new.dashboard
  end
end
