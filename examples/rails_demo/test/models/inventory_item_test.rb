require "test_helper"

class InventoryItemTest < ActiveSupport::TestCase
  test "available stock excludes reservations" do
    assert_equal 12, inventory_items(:one).available_stock
  end
end
