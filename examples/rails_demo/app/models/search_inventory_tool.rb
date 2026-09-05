class SearchInventoryTool < ReplenishmentTool
  description "デモ商品の現在庫、引当、利用可能在庫、発注点をSKUで検索する。分析では最初に必ず使う。"
  parameter :skus, type: :array, description: "対象SKU。全商品なら空配列。"

  def execute(skus: [])
    observed(:search_inventory, { skus: skus }) { { items: @catalog.search_inventory(skus: skus), demo_data: true } }
  end
end
