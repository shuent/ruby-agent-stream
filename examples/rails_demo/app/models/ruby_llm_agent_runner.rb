class RubyLlmAgentRunner
  def initialize(agent)
    @agent = agent
  end

  def each
    return enum_for(:each) unless block_given?

    chat = RubyLLM.chat(model: AgentChat::MODEL, provider: :openai, protocol: :responses,
                        assume_model_exists: true)
                  .with_instructions(AgentChat::SYSTEM_PROMPT)
                  .with_tools(*@agent.tools)
                  .with_tool_options(choice: :auto, calls: :many, concurrency: false)
                  .with_thinking(effort: AgentChat::REASONING.to_sym, display: :summarized)
    @agent.prior_messages.each { |message| chat.add_message(message) }

    provider_events = Enumerator.new do |events|
      steps = 0
      chat.before_message do
        steps += 1
        raise "agent exceeded step limit" if steps > AgentChat::MAX_STEPS
      end
      chat.after_message { |message| events << message if message.tool_result? }
      chat.ask(@agent.prompt) { |chunk| events << chunk }
    end
    inserted_run = false
    AgentStream::Adapters::RubyLLM.new(provider_events, message_id: @agent.message_id).each do |event|
      if event.type == :finish_step && chat.awaiting_approval?
        chat.pending_approvals.each do |call|
          yield @agent.request_approval(call_id: call.id, name: call.name, input: call.arguments)
        end
      end
      yield event
      if event.type == :start_step && !inserted_run
        yield @agent.run_event
        inserted_run = true
      end
    end
  end
end
