require "test_helper"

class InventoryCatalogTest < ActiveSupport::TestCase
  test "calculates an order in supplier pack sizes" do
    proposal = InventoryCatalog.new.calculate_replenishment(skus: ["TEA-GRN"], target_cover_days: 30).sole

    assert_equal 60, proposal.fetch(:recommended_order_quantity)
    assert_equal 45_600, proposal.fetch(:estimated_cost_yen)
    assert_equal 9, proposal.fetch(:available_stock)
  end

end
