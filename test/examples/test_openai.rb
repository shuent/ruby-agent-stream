# frozen_string_literal: true

require "test_helper"
require_relative "../../examples/openai"

# Non-billing provider boundary, real SDK responses and protocol validation.
# rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength
class OpenaiExampleTest < Minitest::Test
  def test_multiple_calls_are_returned_before_the_final_generation
    events, requests = run_agent(response([call("1"), call("2")]), response([assistant_message]))
    assert_equal 2, requests.size
    assert_equal(%w[1 2], requests.last[:input].map { |item| item[:call_id] })
    assert(requests.all? { |request| request[:store] })
    assert(requests.all? { |request| request[:instructions] == requests.first[:instructions] })
    assert_equal "resp-1", requests.last[:previous_response_id]
    assert_equal "Tokyo", JSON.parse(requests.last[:input].first[:output]).fetch("city")
    assert_equal(1, events.count { |event| event.type == :start })
    assert_equal(2, events.count { |event| event.type == :start_step })
    assert_equal "stop", events.last[:finish_reason]
    assert_equal "Sunny", events.find { |event| event.type == :text_delta }[:delta]
    assert_protocol(events)
  end

  def test_single_response_and_tool_results_without_requery
    [[response([assistant_message]), {}], [response([call("1")]), { summarize: false }]].each do |sdk_response, options|
      events, requests = run_agent(sdk_response, **options)
      assert_equal 1, requests.size
      assert_nil requests.first[:previous_response_id]
      assert_equal(1, events.count { |event| event.type == :finish_step })
      assert_equal :finish, events.last.type
      assert_protocol(events)
    end
  end

  def test_failed_incomplete_invalid_input_and_unknown_tool_end_with_error
    bad_call = call("1").merge(arguments: "{broken")
    unknown = call("1").merge(name: "unknown")
    [response([], status: "failed"), response([], status: "incomplete"),
     response([bad_call]), response([unknown])].each do |sdk_response|
      events, requests = run_agent(sdk_response)
      assert_equal 1, requests.size
      assert_equal :error, events.last.type
      assert_protocol(events)
    end
  end

  def test_request_exception_and_step_limit_end_with_error
    events, = run_agent(RuntimeError.new("connection lost"))
    assert_equal "connection lost", events.last[:error_text]
    assert_protocol(events)
    events, requests = run_agent(response([call("1")]), max_steps: 1)
    assert_equal 1, requests.size
    assert_equal :error, events.last.type
    assert_match "exceeded", events.last[:error_text]
    assert_protocol(events)
  end

  private

  def run_agent(*responses, **)
    requests = []
    api = Object.new
    api.define_singleton_method(:create) do |**request|
      requests << request
      value = responses.fetch(requests.size - 1)
      raise value if value.is_a?(Exception)

      value
    end
    events = OpenaiExample.events(client: Struct.new(:responses).new(api), model: "test-model",
                                  prompt: "weather", **).to_a
    [events, requests]
  end

  def response(output, status: "completed")
    OpenAI::Internal::Type::Converter.coerce(OpenAI::Models::Responses::Response,
                                             { id: "resp-1", status: status, model: "test-model", output: output })
  end

  def call(id)
    { type: "function_call", id: "fc-#{id}", call_id: id, name: "weather", arguments: '{"city":"Tokyo"}' }
  end

  def assistant_message
    { type: "message", id: "msg-1", role: "assistant",
      content: [{ type: "output_text", text: "Sunny", annotations: [] }] }
  end

  def assert_protocol(events)
    stream = AgentStream::UIMessage::V1::Stream.new
    events.each { |event| stream << event }
    assert stream.finished?
    assert_equal 1, stream.frames.count("data: [DONE]\n\n")
  end
end
