class OpenaiAgentRunner
  def initialize(agent, client: OpenAI::Client.new(max_retries: 1))
    @agent = agent
    @client = client
    @tools = agent.tools.index_by(&:name)
  end

  def each
    return enum_for(:each) unless block_given?

    yield event(:start, message_id: @agent.message_id)
    previous_response_id = nil
    input = initial_input

    AgentChat::MAX_STEPS.times do |index|
      yield event(:start_step)
      yield @agent.run_event if index.zero?
      sdk_stream = @client.responses.stream(
        model: AgentChat::MODEL, input: input, instructions: AgentChat::SYSTEM_PROMPT,
        tools: tool_definitions, tool_choice: index.zero? ? :required : :auto,
        parallel_tool_calls: true, reasoning: { effort: AgentChat::REASONING.to_sym, summary: :auto },
        previous_response_id: previous_response_id
      )
      adapter = AgentStream::Adapters::OpenAI.new(sdk_stream, lifecycle: :content)
      adapter.each { |provider_event| yield provider_event }
      calls = function_calls(adapter.response)

      waiting = false
      outputs = calls.filter_map do |call|
        if call.name.to_s == "create_replenishment_order"
          yield @agent.request_approval(call_id: call.call_id, name: call.name.to_s, input: JSON.parse(call.arguments))
          waiting = true
          next
        end
        tool = @tools.fetch(call.name.to_s)
        raw_output = tool.call(**JSON.parse(call.arguments).symbolize_keys)
        raw_output = JSON.generate(raw_output) unless raw_output.is_a?(String)
        yield event(:tool_output_available, tool_call_id: call.call_id, output: JSON.parse(raw_output))
        { type: :function_call_output, call_id: call.call_id, output: raw_output }
      end
      yield event(:finish_step)

      if waiting || outputs.empty?
        yield event(:finish, finish_reason: waiting ? :tool_calls : (adapter.finish_reason || :stop))
        return
      end

      previous_response_id = adapter.response.id
      input = outputs
    end

    raise "agent exceeded #{AgentChat::MAX_STEPS} provider steps"
  end

  private

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
