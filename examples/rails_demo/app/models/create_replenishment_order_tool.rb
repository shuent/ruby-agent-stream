class CreateReplenishmentOrderTool < ReplenishmentTool
  description "ユーザーが登録を依頼した補充発注を作成する。SKUと数量の人間の承認が必須。外部仕入先へ送信しない。"
  parameter :sku, type: :string, description: "登録する商品SKU。会話で特定されたSKUを使う。"
  parameter :quantity, type: :integer, description: "登録数量。最小発注数以上、入数の倍数。"
  requires_approval

  def execute(**)
    raise "Business writes must go through AgentApproval#decide!"
  end
end
