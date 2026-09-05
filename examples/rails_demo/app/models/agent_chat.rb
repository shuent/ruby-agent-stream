class AgentChat
  MODEL = AgentCacheKey::MODEL
  REASONING = AgentCacheKey::REASONING
  MAX_STEPS = 6
  ADAPTERS = %w[openai ruby_llm no-llm-call].freeze
  SYSTEM_PROMPT = <<~PROMPT.freeze
    あなたはEC事業者向けの在庫補充アシスタントです。すべて明示的なデモデータです。
    調査の依頼では search_inventory と review_sales を必ず呼び、補充判断ではさらに
    check_supplier_terms と calculate_replenishment を呼んでください。結果を得るまで数値を推測しないでください。
    登録を依頼された場合は先行会話のSKUと指定数量で create_replenishment_order を呼んでください。
    このツールは承認待ちで停止します。承認前に登録完了と述べないでください。外部仕入先への送信はありません。
    通常の調査では登録ツールを使わず、最後は日本語でSKU・補充数・概算費用・根拠を200文字程度にまとめてください。
  PROMPT

  attr_reader :adapter, :messages, :run, :cache_entry, :conversation, :continuation_events

  def initialize(adapter:, messages:, conversation: nil, regenerate: false, debug_error: false)
    @adapter = adapter.to_s
    raise ArgumentError, "unknown adapter" unless ADAPTERS.include?(@adapter)
    @conversation = conversation || AgentConversation.start!(adapter: adapter, session_token: SecureRandom.uuid)
    raise ArgumentError, "会話の接続先が一致しません" unless @conversation.adapter == adapter
    @client_message = Array(messages).last
    @approval_parts = Array(@client_message&.dig("parts")).select { |p| p["state"] == "approval-responded" }
    @continuation_events = @conversation.stored_events if @approval_parts.any?
    @conversation.begin_turn!(@client_message, regenerate: regenerate) if @approval_parts.empty?
    @messages = @conversation.messages
    @normalized_prompt = @approval_parts.any? ? "approval response" : AgentCacheKey.normalize(prompt)
    @digest = AgentCacheKey.digest(adapter: @adapter, messages: @messages, system_prompt: SYSTEM_PROMPT)
    @revision = InventoryCatalog.new.revision
    @cache_entry = AgentCacheEntry.find_by(request_digest: @digest) unless regenerate || @approval_parts.any?
    @debug_error = debug_error
    @run = AgentRun.create!(run_id: SecureRandom.uuid, adapter: @adapter, provider_model: MODEL,
      cache_status: @cache_entry ? "hit" : (regenerate || @approval_parts.any? ? "bypass" : "miss"),
      normalized_prompt: @normalized_prompt, tool_names: "[]", status: "running")
    @tool_records = []
  end

  def each
    return enum_for(:each) unless block_given?
    raise "検証用に注入したサーバーエラー" if @debug_error
    events = []
    source = if @approval_parts.any?
      approval_events
    elsif cache_entry
      AgentEventLog.load(cache_entry.event_log, run_event: run_event)
    else
      adapter == "openai" ? OpenaiAgentRunner.new(self) : RubyLlmAgentRunner.new(self)
    end
    source.each do |event|
      events << event
      if event.type == :finish
        raise "元データが更新されました。新しい会話でやり直してください" if @approval_parts.empty? && @revision != InventoryCatalog.new.revision
        conversation.save_events!(events, continuation: @approval_parts.any?)
        complete!(events)
      end
      yield event
    end
    raise "agent stream did not finish successfully" unless events.last&.type == :finish
  rescue StandardError => error
    run&.update!(status: "error", error_message: error.message)
    conversation.update!(active_run: nil) if conversation&.persisted?
    raise
  end

  def message_id
    "agent-#{run.run_id}"
  end

  def request_approval(call_id:, name:, input:)
    input = input.deep_stringify_keys
    InventoryCatalog.new.validate_order!(input)
    approval = conversation.agent_approvals.create!(public_id: SecureRandom.uuid, message_id: message_id,
      tool_call_id: call_id, tool_name: name, input: input, data_revision: @revision)
    observe_tool(name, input, { status: "awaiting_approval", approval_id: approval.public_id })
    event(:tool_approval_request, approval_id: approval.public_id, tool_call_id: call_id)
  end

  def observe_tool(name, input, output)
    @tool_records << { name: name, call_index: @tool_records.length + 1, input: input, output: output }
  end

  def tools
    [SearchInventoryTool, ReviewSalesTool, CheckSupplierTermsTool, CalculateReplenishmentTool,
     CreateReplenishmentOrderTool].map { |klass| klass.new(observer: method(:observe_tool)) }
  end

  def prompt
    AgentCacheKey.message_text(messages.last)
  end

  def prior_messages
    messages[0...-1].filter_map do |message|
      text = AgentCacheKey.message_text(message)
      results = Array(message["parts"]).filter_map do |part|
        JSON.generate(part.slice("type", "input", "output", "state")) if part["type"].start_with?("tool-")
      end
      content = ([text] + results).reject(&:empty?).join("\n")
      { role: message.fetch("role"), content: content } unless content.empty?
    end
  end

  def run_event
    event(:data, name: "run", transient: true, data: { run_id: run.run_id, adapter: adapter, model: MODEL,
      reasoning_effort: REASONING, cache_status: run.cache_status, seed_version: InventoryCatalog::SEED_VERSION })
  end

  private

  def approval_events
    Enumerator.new do |out|
      approvals = @approval_parts.map do |part|
        approval = conversation.agent_approvals.find_by!(public_id: part.dig("approval", "id"))
        approval.decide!(part: part, message_id: @client_message.fetch("id"))
        approval.reload
      end
      out << event(:start, message_id: @client_message.fetch("id"))
      out << event(:start_step)
      out << run_event
      approvals.each do |approval|
        out << event(:tool_approval_response, approval_id: approval.public_id, approved: approval.status == "executed")
        out << case approval.status
        when "executed" then event(:tool_output_available, tool_call_id: approval.tool_call_id, output: approval.outcome)
        else event(:tool_output_denied, tool_call_id: approval.tool_call_id)
        end
        observe_tool(approval.tool_name, approval.input, approval.outcome)
      end
      text = if approvals.all? { |a| a.status == "executed" }
        "補充発注をデモDBに登録しました。ダッシュボードに反映済みです。外部仕入先への送信はしていません。"
      elsif approvals.any? { |a| a.status == "stale" }
        "元データが更新されたため登録しませんでした。新しい会話で再提案してください。"
      else
        "登録を拒否しました。業務データは変更していません。"
      end
      out << event(:text_start, id: "approval-result-#{run.run_id}")
      out << event(:text_delta, id: "approval-result-#{run.run_id}", delta: text)
      out << event(:text_end, id: "approval-result-#{run.run_id}")
      out << event(:finish_step)
      out << event(:finish, finish_reason: :stop)
    end
  end

  def complete!(events)
    reasoning = events.any? { |e| e.type == :reasoning_delta }
    tool_names = @tool_records.map { |r| r.fetch(:name) }.uniq
    if cache_entry
      tool_names = cache_entry.metadata.fetch(:tool_names, [])
      reasoning = cache_entry.metadata.fetch(:reasoning_observed, false)
    elsif @approval_parts.empty? && !events.any? { |e| e.type == :tool_approval_request }
      AgentCacheEntry.upsert({ request_digest: @digest, adapter: adapter, provider_model: MODEL,
        normalized_prompt: @normalized_prompt, event_log: AgentEventLog.dump(events),
        run_metadata: JSON.generate(tool_names: tool_names, tool_calls: @tool_records, reasoning_observed: reasoning),
        created_at: Time.current, updated_at: Time.current }, unique_by: :request_digest)
    end
    run.update!(status: events.any? { |e| e.type == :tool_approval_request } ? "awaiting_approval" : "completed",
                tool_names: JSON.generate(tool_names), reasoning_observed: reasoning)
  end

  def event(type, **attributes)
    AgentStream::UIMessage::V1::Event.new(type, **attributes)
  end
end
