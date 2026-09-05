require "test_helper"

class InventoryCatalogTest < ActiveSupport::TestCase
  test "calculates an order in supplier pack sizes" do
    proposal = InventoryCatalog.new.calculate_replenishment(skus: ["TEA-GRN"], target_cover_days: 30).sole

    assert_equal 60, proposal.fetch(:recommended_order_quantity)
    assert_equal 45_600, proposal.fetch(:estimated_cost_yen)
    assert_equal 9, proposal.fetch(:available_stock)
  end

  test "cache digest separates adapters, context, and normalized prompt" do
    messages = [{ "role" => "user", "parts" => [{ "type" => "text", "text" => "  在庫を\n確認  " }] }]
    same_prompt = [{ "role" => "user", "parts" => [{ "type" => "text", "text" => "在庫を 確認" }] }]

    first = AgentCacheKey.digest(adapter: "openai", messages: messages, system_prompt: AgentChat::SYSTEM_PROMPT)
    normalized = AgentCacheKey.digest(adapter: "openai", messages: same_prompt, system_prompt: AgentChat::SYSTEM_PROMPT)
    other_adapter = AgentCacheKey.digest(adapter: "ruby_llm", messages: same_prompt, system_prompt: AgentChat::SYSTEM_PROMPT)

    assert_equal first, normalized
    assert_not_equal first, other_adapter
  end
end
