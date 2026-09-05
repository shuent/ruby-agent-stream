class InventoryCatalog
  SEED_VERSION = "inventory-demo-v1"
  TOOL_VERSION = "replenishment-tools-v2-approval"

  def dashboard
    { demo_data: true, revision: revision, inventory: search_inventory, sales: review_sales,
      suppliers: check_supplier_terms, orders: ReplenishmentOrder.order(id: :desc).map(&:public_result) }
  end

  def revision
    ApplicationRecord.uncached do
      Digest::SHA256.hexdigest(JSON.generate([DemoRevision.token, search_inventory, review_sales,
                                              check_supplier_terms, ReplenishmentOrder.order(:id).pluck(:id)]))
    end
  end

  def validate_order!(input)
    raise ArgumentError, "SKUと数量だけを指定してください" unless input.keys.sort == %w[quantity sku]
    item = InventoryItem.find_by!(sku: input.fetch("sku"))
    quantity = input.fetch("quantity")
    term = item.supplier_term
    unless quantity.is_a?(Integer) && quantity.between?(term.min_order_quantity, 10_000) && (quantity % term.pack_size).zero?
      raise ArgumentError, "数量は最小発注数#{term.min_order_quantity}以上、入数#{term.pack_size}の倍数で指定してください"
    end
    item
  end

  def register_order!(input:, approval:)
    raise ArgumentError, "未承認の登録です" unless approval.status == "pending" && approval.input == input
    item = validate_order!(input)
    order = ReplenishmentOrder.create!(agent_approval: approval, sku: item.sku, quantity: input.fetch("quantity"),
                                      supplier_name: item.supplier_term.supplier_name,
                                      estimated_cost_yen: input.fetch("quantity") * item.supplier_term.unit_cost.to_i)
    DemoRevision.invalidate!
    order.public_result
  end

  def search_inventory(skus: nil)
    items(skus).map do |item|
      {
        sku: item.sku, name: item.name, category: item.category,
        stock_on_hand: item.stock_on_hand, stock_reserved: item.stock_reserved,
        available_stock: item.available_stock, reorder_point: item.reorder_point,
        below_reorder_point: item.available_stock < item.reorder_point
      }
    end
  end

  def review_sales(skus: nil, period_days: 30)
    items(skus).map do |item|
      metric = item.sales_metrics.find_by!(period_days: period_days)
      daily_velocity = metric.units_sold.fdiv(metric.period_days)
      {
        sku: item.sku, name: item.name, period_days: metric.period_days,
        units_sold: metric.units_sold, daily_velocity: daily_velocity.round(2),
        days_of_cover: daily_velocity.zero? ? nil : (item.available_stock / daily_velocity).round(1)
      }
    end
  end

  def check_supplier_terms(skus: nil)
    items(skus).map do |item|
      term = item.supplier_term
      {
        sku: item.sku, name: item.name, supplier_name: term.supplier_name,
        lead_time_days: term.lead_time_days, min_order_quantity: term.min_order_quantity,
        pack_size: term.pack_size, unit_cost_yen: term.unit_cost.to_i
      }
    end
  end

  def calculate_replenishment(skus: nil, target_cover_days: 30)
    items(skus).map do |item|
      metric = item.sales_metrics.find_by!(period_days: 30)
      term = item.supplier_term
      target_stock = (metric.units_sold.fdiv(metric.period_days) * target_cover_days).ceil
      shortage = [target_stock - item.available_stock, 0].max
      requested = [shortage, term.min_order_quantity].max
      quantity = shortage.zero? ? 0 : (requested.fdiv(term.pack_size).ceil * term.pack_size)
      {
        sku: item.sku, name: item.name, target_cover_days: target_cover_days,
        available_stock: item.available_stock, target_stock: target_stock,
        recommended_order_quantity: quantity, estimated_cost_yen: quantity * term.unit_cost.to_i,
        supplier_name: term.supplier_name, lead_time_days: term.lead_time_days,
        basis: "30日販売実績、利用可能在庫、最小発注数、入数で計算したデモ提案"
      }
    end
  end

  private

  def items(skus)
    scope = InventoryItem.includes(:sales_metrics, :supplier_term).order(:sku)
    selected = Array(skus).map { |sku| sku.to_s.upcase.strip }.reject(&:empty?)
    scope = scope.where(sku: selected) if selected.any?
    scope.to_a
  end
end
