class SalesMetric < ApplicationRecord
  belongs_to :inventory_item
  validates :period_days, :units_sold, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
