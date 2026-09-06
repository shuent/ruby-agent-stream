class OpenaiAgentRunner
  def initialize(agent, client: OpenAI::Client.new(max_retries: 1))
    @agent = agent
    @client = client
    @tools = agent.tools.index_by(&:name)
  end

  def each
    return enum_for(:each) unless block_given?

    @consumer_failed = false
    run do |value|
      yield value
    rescue StandardError
      @consumer_failed = true
      raise
    end
    self
  end

  private

  def run
    @parts = {}
    @active_step = false
    yield event(:start, message_id: @agent.message_id)
    previous_response_id = nil
    input = initial_input

    AgentChat::MAX_STEPS.times do |index|
      yield event(:start_step)
      @active_step = true
      yield @agent.run_event if index.zero?
      # Provider context is retained only within this run. New user turns use
      # the application's trusted conversation history through initial_input.
      sdk_stream = @client.responses.stream(
        model: AgentChat::MODEL, input: input, instructions: AgentChat::SYSTEM_PROMPT,
        tools: tool_definitions, tool_choice: index.zero? ? :required : :auto,
        parallel_tool_calls: true, reasoning: { effort: AgentChat::REASONING.to_sym, summary: :auto },
        store: true, previous_response_id: previous_response_id
      )
      response = read_response(sdk_stream) { |part| yield part }
      calls = function_calls(response)
      waiting = false
      outputs = calls.filter_map do |call|
        arguments = JSON.parse(call.arguments)
        yield event(:tool_input_available, tool_call_id: call.call_id, tool_name: call.name.to_s, input: arguments)
        if call.name.to_s == "create_replenishment_order"
          yield @agent.request_approval(call_id: call.call_id, name: call.name.to_s, input: arguments)
          waiting = true
          next
        end
        tool = @tools.fetch(call.name.to_s)
        raw_output = tool.call(**arguments.symbolize_keys)
        raw_output = JSON.generate(raw_output) unless raw_output.is_a?(String)
        yield event(:tool_output_available, tool_call_id: call.call_id, output: JSON.parse(raw_output))
        { type: :function_call_output, call_id: call.call_id, output: raw_output }
      end
      yield event(:finish_step)
      @active_step = false

      # response.completed ends one generation, not the agent's turn.
      # Approval ends this HTTP segment; its continuation never calls the LLM.
      if waiting || calls.empty?
        yield event(:finish, finish_reason: waiting ? :tool_calls : :stop)
        return
      end
      previous_response_id = response.id
      input = outputs
    end
    raise "agent exceeded #{AgentChat::MAX_STEPS} provider steps"
  rescue StandardError => error
    raise if @consumer_failed

    close_parts { |part| yield part }
    yield event(:finish_step) if @active_step
    yield event(:error, error_text: error.message)
  end

  # These mappings belong to this agent, alongside its SDK request and stop policy.
  # Function inputs are published from the completed response, before execution.
  def read_response(sdk_stream)
    completed = nil
    sdk_stream.each do |sdk_event|
      case sdk_event.type.to_s
      when "response.output_text.delta", "response.refusal.delta"
        id = "#{sdk_event.item_id}:content:#{sdk_event.content_index}"
        delta(:text, id, sdk_event.delta) { |part| yield part }
      when "response.reasoning_summary_text.delta"
        id = "#{sdk_event.item_id}:summary:#{sdk_event.summary_index}"
        delta(:reasoning, id, sdk_event.delta) { |part| yield part }
      when "response.reasoning_text.delta"
        id = "#{sdk_event.item_id}:content:#{sdk_event.content_index}"
        delta(:reasoning, id, sdk_event.delta) { |part| yield part }
      when "response.output_text.done", "response.refusal.done", "response.reasoning_text.done"
        close_part("#{sdk_event.item_id}:content:#{sdk_event.content_index}") { |part| yield part }
      when "response.reasoning_summary_text.done"
        close_part("#{sdk_event.item_id}:summary:#{sdk_event.summary_index}") { |part| yield part }
      when "response.completed"
        completed = sdk_event.response
        break
      when "response.failed"
        raise(sdk_event.response.error&.message || "OpenAI response failed")
      when "response.incomplete"
        raise "OpenAI response incomplete: #{sdk_event.response.incomplete_details&.reason}"
      when "error"
        raise sdk_event.message
      end
    end
    raise "OpenAI stream ended without response.completed" unless completed

    close_parts { |part| yield part }
    metadata = { provider: "openai", response_id: completed.id, model: completed.model.to_s }
    metadata[:usage] = JSON.parse(JSON.generate(completed.usage.to_h)) if completed.usage
    yield event(:message_metadata, message_metadata: metadata)
    completed
  end

  def delta(kind, id, text)
    unless @parts.key?(id)
      yield event(:"#{kind}_start", id: id)
      @parts[id] = kind
    end
    yield event(:"#{kind}_delta", id: id, delta: text)
  end

  def close_part(id)
    kind = @parts.delete(id)
    yield event(:"#{kind}_end", id: id) if kind
  end

  def close_parts(&block)
    @parts.keys.each { |id| close_part(id, &block) }
  end

  def initial_input
    (@agent.prior_messages + [{ role: "user", content: @agent.prompt }]).map do |message|
      { role: message.fetch(:role).to_sym, content: message.fetch(:content) }
    end
  end

  def tool_definitions
    @tools.values.map do |tool|
      parameters = Marshal.load(Marshal.dump(tool.parameters_schema))
      parameters.delete("strict")
      { type: :function, name: tool.name, description: tool.description, parameters: parameters, strict: true }
    end
  end

  def function_calls(response)
    Array(response.output).select { |item| item.type.to_sym == :function_call }
  end

  def event(type, **attributes)
    AgentStream::UIMessage::V1::Event.new(type, **attributes)
  end
end
