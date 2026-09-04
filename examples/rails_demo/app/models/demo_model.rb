# A deterministic model stand-in that streams plain provider event objects.
# It deliberately knows nothing about AgentStream.
class DemoModel
  ProviderEvent = Data.define(:type, :payload)

  def initialize(sleeper: Kernel.method(:sleep))
    @sleeper = sleeper
  end

  def stream(scenario:)
    provider_events = scenario.to_s == "error" ? error_events : complete_events
    delay = scenario.to_s == "slow" ? 0.15 : 0.015

    Enumerator.new do |events|
      provider_events.each do |event|
        events << event
        @sleeper.call(delay)
      end
    end
  end

  private

  def complete_events
    [
      event(:start, message_id: "rails-demo-assistant"),
      event(:start_step),
      event(:reasoning_start, id: "reasoning-1"),
      event(:reasoning_delta, id: "reasoning-1", delta: "Choose the appropriate response. "),
      event(:reasoning_end, id: "reasoning-1"),
      event(:text_start, id: "text-1"),
      event(:text_delta, id: "text-1", delta: "These plain model events are "),
      event(:text_delta, id: "text-1", delta: "converted by an Enumerator."),
      event(:text_end, id: "text-1"),
      event(:tool_input_start, tool_call_id: "call-weather", tool_name: "weather"),
      event(:tool_input_delta, tool_call_id: "call-weather", input_text_delta: '{"city":"Tokyo"}'),
      event(:tool_input_available, tool_call_id: "call-weather", tool_name: "weather", input: { city: "Tokyo" }),
      event(:finish_step),
      event(:finish, finish_reason: :tool_calls)
    ]
  end

  def error_events
    [
      event(:start, message_id: "rails-demo-error"),
      event(:start_step),
      event(:finish_step),
      event(:error, error_text: "Synthetic provider failure")
    ]
  end

  def event(type, **payload)
    ProviderEvent.new(type:, payload:)
  end
end
