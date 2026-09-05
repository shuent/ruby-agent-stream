class InventoryItem < ApplicationRecord
  has_many :sales_metrics, dependent: :destroy
  has_one :supplier_term, dependent: :destroy

  validates :sku, :name, :category, presence: true
  validates :sku, uniqueness: true

  def available_stock
    stock_on_hand - stock_reserved
  end
end
