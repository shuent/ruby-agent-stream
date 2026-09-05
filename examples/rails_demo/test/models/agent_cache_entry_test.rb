require "test_helper"

class AgentCacheEntryTest < ActiveSupport::TestCase
  test "request digest is unique" do
    duplicate = agent_cache_entries(:one).dup
    assert_not duplicate.valid?
  end


  test "cache key includes tool results from the relevant conversation" do
    base = [{ "role" => "assistant", "parts" => [
      { "type" => "tool-search_inventory", "toolCallId" => "call-1", "state" => "output-available",
        "input" => { "skus" => ["TEA-GRN"] }, "output" => { "items" => [{ "available_stock" => 9 }] } }
    ] }]
    changed = Marshal.load(Marshal.dump(base))
    changed[0]["parts"][0]["output"]["items"][0]["available_stock"] = 10

    first = AgentCacheKey.digest(adapter: "openai", messages: base, system_prompt: "system")
    second = AgentCacheKey.digest(adapter: "openai", messages: changed, system_prompt: "system")

    assert_not_equal first, second
  end
end
