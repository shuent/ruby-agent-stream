require "json"
require "openai"

# API-key-free stand-in for OpenAI::Client#responses.stream. It returns real
# openai-ruby event model instances decoded from the repository fixture.
class DemoModel
  FIXTURE_PATH = Rails.root.join("../../test/fixtures/openai/responses_stream.jsonl").expand_path.freeze

  def initialize(sleeper: Kernel.method(:sleep))
    @sleeper = sleeper
  end

  def responses_stream(scenario:)
    events = scenario.to_s == "error" ? error_events : fixture_events
    delay = scenario.to_s == "slow" ? 0.15 : 0.015

    Enumerator.new do |stream|
      events.each do |event|
        stream << event
        @sleeper.call(delay)
      end
    end
  end

  private

  def fixture_events
    FIXTURE_PATH.each_line(chomp: true).reject(&:empty?).map do |line|
      coerce(JSON.parse(line, symbolize_names: true))
    end
  end

  def error_events
    [
      OpenAI::Models::Responses::ResponseErrorEvent.new(
        code: "server_error",
        message: "Synthetic provider failure",
        param: nil,
        sequence_number: 0
      )
    ]
  end

  def coerce(attributes)
    OpenAI::Internal::Type::Converter.coerce(
      OpenAI::Models::Responses::ResponseStreamEvent,
      attributes
    )
  end
end
