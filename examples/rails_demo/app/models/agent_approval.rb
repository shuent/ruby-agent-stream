class AgentApproval < ApplicationRecord
  belongs_to :agent_conversation

  # Transaction and unique order approval_id provide one business write, even
  # when a decision is replayed. Never call the tool using client-side arguments.
  def decide!(part:, message_id:)
    with_lock do
      raise ArgumentError, "承認対象が一致しません" unless self.message_id == message_id &&
        part.fetch("toolCallId") == tool_call_id && part.fetch("input") == input &&
        part.fetch("type") == "tool-#{tool_name}" && part.fetch("approval").fetch("id") == public_id
      approved = part.fetch("approval").fetch("approved")
      raise ArgumentError, "承認は真偽値で指定してください" unless [true, false].include?(approved)
      return outcome if status != "pending"

      if data_revision != InventoryCatalog.new.revision
        update!(status: "stale", outcome: { error: "データが更新されました。新しい会話で再提案してください。" })
      elsif !approved
        update!(status: "denied", outcome: { denied: true })
      else
        result = InventoryCatalog.new.register_order!(input: input, approval: self)
        update!(status: "executed", outcome: { order: result, demo_data: true })
      end
      outcome
    end
  end
end
