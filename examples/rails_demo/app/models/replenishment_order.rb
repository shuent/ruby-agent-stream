class ReplenishmentOrder < ApplicationRecord
  belongs_to :agent_approval
  validates :sku, :supplier_name, presence: true
  validates :quantity, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 10_000 }

  def public_result
    attributes.slice("id", "sku", "quantity", "supplier_name", "estimated_cost_yen", "status")
  end
end
