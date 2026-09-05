class SupplierTerm < ApplicationRecord
  belongs_to :inventory_item
  validates :supplier_name, presence: true
  validates :lead_time_days, :min_order_quantity, :pack_size,
            numericality: { only_integer: true, greater_than: 0 }
  validates :unit_cost, numericality: { greater_than: 0 }
end
