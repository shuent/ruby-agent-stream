require "digest"

class AgentCacheKey
  MODEL = "gpt-5.6-luna"
  REASONING = "medium"

  def self.normalize(text)
    text.to_s.unicode_normalize(:nfkc).gsub(/\s+/, " ").strip
  end

  def self.digest(adapter:, messages:, system_prompt:)
    context = messages.map do |message|
      { role: message.fetch("role"), parts: context_parts(message) }
    end
    Digest::SHA256.hexdigest(JSON.generate(
      adapter: adapter, model: MODEL, reasoning: REASONING,
      system_prompt: system_prompt, tool_version: InventoryCatalog::TOOL_VERSION,
      seed_version: InventoryCatalog::SEED_VERSION, data_revision: InventoryCatalog.new.revision, context: context
    ))
  end

  def self.message_text(message)
    Array(message["parts"]).filter_map do |part|
      part["text"] if part["type"] == "text"
    end.join("\n")
  end

  def self.context_parts(message)
    Array(message["parts"]).filter_map do |part|
      case part["type"]
      when "text"
        { type: "text", text: normalize(part["text"]) }
      when /\Atool-/, "dynamic-tool"
        {
          type: part["type"], tool_name: part["toolName"], tool_call_id: part["toolCallId"],
          state: part["state"], input: part["input"], output: part["output"]
        }.compact
      end
    end
  end
end
