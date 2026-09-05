class ReviewSalesTool < ReplenishmentTool
  description "デモ商品の直近販売数、日次販売速度、在庫日数を調べる。在庫だけで判断せず必ず使う。"
  parameter :skus, type: :array, description: "対象SKU。全商品なら空配列。"
  parameter :period_days, type: :integer, description: "集計期間。デモは30日のみ。"

  def execute(skus: [], period_days: 30)
    observed(:review_sales, { skus: skus, period_days: period_days }) do
      { items: @catalog.review_sales(skus: skus, period_days: period_days), demo_data: true }
    end
  end
end
