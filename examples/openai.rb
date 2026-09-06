# frozen_string_literal: true

require "json"
require "openai"
require "ai_stream"

# A complete, Rails-free agent. This example buffers each SDK response with
# create; the Rails example also streams text/reasoning deltas as they arrive.
module OpenaiExample
  Event = AgentStream::UIMessage::V1::Event
  TOOLS = [{ type: :function, name: "weather", description: "Get demo weather for a city.",
             parameters: { type: :object, properties: { city: { type: :string } },
                           required: ["city"], additionalProperties: false }, strict: true }].freeze

  def self.weather(city:)
    { city: city, temperature: 24, unit: "celsius", demo: true }
  end

  # Set summarize: false to display tool results and return without another call.
  def self.events(client:, model:, prompt:, summarize: true, max_steps: 6)
    Enumerator.new do |out|
      out << Event.new(:start, message_id: "assistant-1")
      active_step = false
      previous_response_id = nil
      input = prompt
      stopped = false
      max_steps.times do |index|
        out << Event.new(:start_step)
        active_step = true
        response = client.responses.create(
          model: model, input: input, tools: TOOLS, store: true,
          instructions: "Use weather for weather questions. Explain that its data is demo data.",
          previous_response_id: previous_response_id
        )
        raise "OpenAI response #{response.status}" unless response.status.to_s == "completed"

        out << Event.new(:message_metadata, message_metadata: {
          provider: "openai", response_id: response.id, model: response.model.to_s
        })
        response.output.each do |item|
          next unless item.type.to_s == "message"

          Array(item.content).each_with_index do |part, part_index|
            text = part.type.to_s == "refusal" ? part.refusal : part.text
            id = "text-#{index}-#{item.id}-#{part_index}"
            out << Event.new(:text_start, id: id)
            out << Event.new(:text_delta, id: id, delta: text)
            out << Event.new(:text_end, id: id)
          end
        end
        calls = response.output.select { |item| item.type.to_s == "function_call" }
        input = calls.map do |call|
          arguments = JSON.parse(call.arguments, symbolize_names: true)
          out << Event.new(:tool_input_available, tool_call_id: call.call_id, tool_name: call.name, input: arguments)
          raise "unknown tool: #{call.name}" unless call.name == "weather"

          output = weather(**arguments)
          out << Event.new(:tool_output_available, tool_call_id: call.call_id, output: output)
          { type: :function_call_output, call_id: call.call_id, output: JSON.generate(output) }
        end
        out << Event.new(:finish_step)
        active_step = false
        if calls.empty? || !summarize
          out << Event.new(:finish, finish_reason: calls.empty? ? :stop : :tool_calls)
          stopped = true
          break
        end
        previous_response_id = response.id
      end
      raise "agent exceeded #{max_steps} provider steps" unless stopped
    rescue StandardError => error
      out << Event.new(:finish_step) if active_step
      out << Event.new(:error, error_text: error.message)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  prompt = ARGV.empty? ? "What is the weather in Tokyo?" : ARGV.join(" ")
  ui_stream = AgentStream::UIMessage::V1::Stream.new($stdout)
  OpenaiExample.events(client: OpenAI::Client.new, model: ENV.fetch("OPENAI_MODEL"), prompt: prompt)
               .each { |event| ui_stream << event }
end
