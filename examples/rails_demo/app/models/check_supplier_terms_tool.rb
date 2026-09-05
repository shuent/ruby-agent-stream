class CheckSupplierTermsTool < ReplenishmentTool
  description "仕入先、納期、最小発注数、入数、単価を調べる。発注提案の前に必ず使う。"
  parameter :skus, type: :array, description: "対象SKU。全商品なら空配列。"

  def execute(skus: [])
    observed(:check_supplier_terms, { skus: skus }) { { items: @catalog.check_supplier_terms(skus: skus), demo_data: true } }
  end
end
