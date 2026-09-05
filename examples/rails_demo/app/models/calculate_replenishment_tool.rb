class CalculateReplenishmentTool < ReplenishmentTool
  description "販売速度、利用可能在庫、仕入条件を使って補充数と概算費用を計算する。調査後の最終計算に使う。"
  parameter :skus, type: :array, description: "対象SKU。全商品なら空配列。"
  parameter :target_cover_days, type: :integer, description: "補充後に確保したい在庫日数。"

  def execute(skus: [], target_cover_days: 30)
    observed(:calculate_replenishment, { skus: skus, target_cover_days: target_cover_days }) do
      { proposals: @catalog.calculate_replenishment(skus: skus, target_cover_days: target_cover_days), demo_data: true }
    end
  end
end
