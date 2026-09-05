class ReplenishmentTool < RubyLLM::Tool
  def initialize(catalog: InventoryCatalog.new, observer: nil)
    super()
    @catalog = catalog
    @observer = observer
  end

  private

  def observed(name, input)
    result = yield
    @observer&.call(name.to_s, input, result)
    JSON.generate(result)
  rescue StandardError => error
    @observer&.call(name.to_s, input, { error: error.message })
    raise
  end
end
