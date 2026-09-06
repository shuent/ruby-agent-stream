class AgentConversation < ApplicationRecord
  has_many :agent_approvals, dependent: :destroy

  def self.start!(adapter:, session_token:)
    raise ArgumentError, "unknown adapter" unless AgentChat::ADAPTERS.include?(adapter)
    create!(public_id: SecureRandom.uuid, adapter: adapter, session_digest: session_digest_for(session_token))
  end

  def self.for_session!(id, token)
    find_by!(public_id: id, session_digest: session_digest_for(token))
  end

  def self.session_digest_for(token)
    raise ArgumentError, "ブラウザセッションが必要です" unless token.to_s.match?(/\A[\w-]{24,100}\z/)
    Digest::SHA256.hexdigest(token)
  end

  def self.for_session(token)
    where(session_digest: session_digest_for(token)).where("json_array_length(messages) > 0").order(updated_at: :desc, id: :desc)
  end

  def self.message_text(message)
    Array(message&.dig("parts")).filter_map { |part| part["text"] if part["type"] == "text" }.join("\n")
  end

  def summary
    first = messages.find { |message| message["role"] == "user" }
    title = self.class.message_text(first).gsub(/\s+/, " ").strip
    { id: public_id, adapter: adapter, title: title.present? ? title.truncate(60) : "新しい会話", updated_at: updated_at }
  end

  def public_result
    summary.merge(messages: messages)
  end

  def begin_turn!(client_message, regenerate: false)
    with_lock do
      raise ArgumentError, "この会話は実行中です" if active_run.present?
      raise ArgumentError, "先に承認または拒否してください" if agent_approvals.where(status: "pending").exists?
      history = messages.deep_dup
      if regenerate
        raise ArgumentError, "登録提案は再生成できません。新しい会話を開始してください" if agent_approvals.exists?
        raise ArgumentError, "再生成する発言がありません" unless history.any? { |m| m["role"] == "user" }
        history.pop if history.last&.fetch("role") == "assistant"
      else
        raise ArgumentError, "user message required" unless client_message&.fetch("role", nil) == "user"
        text = self.class.message_text(client_message).strip
        raise ArgumentError, "入力は1〜4000文字で指定してください" unless text.length.between?(1, 4000)
        history << { "id" => client_message["id"] || SecureRandom.uuid, "role" => "user", "parts" => [{ "type" => "text", "text" => text }] }
      end
      update!(messages: history, active_run: SecureRandom.uuid)
    end
  end

  # A compact projection of saved protocol events, solely to restore useChat on
  # reload. It is not a second client-side chat state machine.
  def save_events!(events, continuation: false)
    with_lock do
      history = messages.deep_dup
      assistant = continuation ? history.pop : { "id" => events.find { |e| e.type == :start }.attributes.fetch(:message_id), "role" => "assistant", "parts" => [] }
      parts = assistant.fetch("parts")
      text_parts = {}
      events.each do |event|
        a = event.attributes.deep_stringify_keys
        case event.type
        when :start_step then parts << { "type" => "step-start" }
        when :text_start, :reasoning_start
          type = event.type == :text_start ? "text" : "reasoning"
          part = { "type" => type, "text" => String.new, "state" => "done" }
          parts << part
          text_parts[a.fetch("id")] = part
        when :text_delta, :reasoning_delta then text_parts.fetch(a.fetch("id"))["text"] << a.fetch("delta")
        when :tool_input_available
          parts << { "type" => "tool-#{a.fetch('tool_name')}", "toolCallId" => a.fetch("tool_call_id"), "input" => a.fetch("input"), "state" => "input-available" }
        when :tool_approval_request
          part = parts.find { |p| p["toolCallId"] == a["tool_call_id"] }
          part.merge!("state" => "approval-requested", "approval" => { "id" => a.fetch("approval_id") })
        when :tool_approval_response
          part = parts.find { |p| p.dig("approval", "id") == a["approval_id"] }
          part["approval"]["approved"] = a.fetch("approved")
        when :tool_output_available, :tool_output_error, :tool_output_denied
          part = parts.find { |p| p["toolCallId"] == a["tool_call_id"] }
          part["state"] = event.type.to_s.tr("_", "-").delete_prefix("tool-")
          part["output"] = a["output"] if a.key?("output")
          part["errorText"] = a["error_text"] if a.key?("error_text")
        end
      end
      history << assistant
      log = continuation ? last_events : event_rows(events)
      update!(messages: history, last_events: log, active_run: nil)
    end
  end

  def stored_events
    last_events.map { |row| AgentStream::UIMessage::V1::Event.new(row.fetch("type"), **row.fetch("attributes").deep_symbolize_keys) }
  end

  private

  def event_rows(events)
    events.map { |e| { type: e.type, attributes: e.attributes } }
  end
end
