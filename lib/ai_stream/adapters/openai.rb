# frozen_string_literal: true

require "json"
require "openai"

require_relative "../adapters"

module AgentStream
  module Adapters
    # Converts official openai-ruby Responses streaming events into validated
    # AI SDK UI Message Stream Protocol events.
    # rubocop:disable Metrics/ClassLength, Metrics/MethodLength, Metrics/AbcSize
    # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    class OpenAI
      include Enumerable

      attr_reader :finish_reason, :response

      IGNORED_EVENT_PREFIXES = %w[
        response.audio. response.code_interpreter_call. response.file_search_call.
        response.image_generation_call. response.mcp_call. response.shell_call.
        response.web_search_call. response.in_progress response.output_text.annotation.
      ].freeze

      def initialize(events, message_id: nil, lifecycle: :message)
        @events = events
        @message_id = message_id
        @lifecycle = lifecycle
      end

      def each(&consumer)
        return enum_for(:each) unless consumer

        reset(consumer)
        @events.each { |event| dispatch(event) }
        finish unless @emitter.finished?
        self
      end

      private

      def reset(consumer)
        @emitter = Emitter.new(message_id: @message_id, consumer: consumer, lifecycle: @lifecycle)
        @tools = {}
        @part_kinds = {}
        @response = nil
        @finish_reason = nil
        @saw_tool_call = false
      end

      def dispatch(event)
        type = event_type(event)
        case type
        when :"response.created" then created(event)
        when :"response.output_item.added" then output_item_added(event)
        when :"response.content_part.added" then content_part_added(event)
        when :"response.content_part.done" then content_part_done(event)
        when :"response.output_text.delta", :"response.refusal.delta" then text_delta(event)
        when :"response.output_text.done", :"response.refusal.done" then text_done(event)
        when :"response.reasoning_summary_part.added" then reasoning_summary_added(event)
        when :"response.reasoning_summary_text.delta" then reasoning_summary_delta(event)
        when :"response.reasoning_summary_part.done", :"response.reasoning_summary_text.done"
          reasoning_summary_done(event)
        when :"response.reasoning_text.delta" then reasoning_text_delta(event)
        when :"response.reasoning_text.done" then reasoning_text_done(event)
        when :"response.function_call_arguments.delta" then function_arguments_delta(event)
        when :"response.function_call_arguments.done" then function_arguments_done(event)
        when :"response.output_item.done" then output_item_done(event)
        when :"response.completed" then completed(event)
        when :"response.incomplete" then incomplete(event)
        when :"response.failed" then failed(event)
        when :error then provider_error(event)
        else
          ignore_or_reject(event, type)
        end
      end

      def event_type(event)
        type = event.type if event.respond_to?(:type)
        return type.to_sym if type

        raise UnsupportedEventError, "expected an openai-ruby streaming event, got #{event.class}"
      end

      def created(event)
        @response = event.response
        @emitter.start(@response.id)
      end

      def output_item_added(event)
        item = event.item
        return unless item_type(item) == :function_call

        register_tool(item.id, call_id: item.call_id, name: item.name, arguments: item.arguments)
      end

      def content_part_added(event)
        part = event.part
        kind = part_kind(item_type(part))
        return unless kind

        id = content_part_id(event.item_id, event.content_index)
        @part_kinds[id] = kind
        @emitter.start_part(kind, id, provider_metadata: openai_metadata(item_id: event.item_id))
        initial = part.respond_to?(:text) ? part.text : nil
        @emitter.delta_part(kind, id, initial) if initial && !initial.empty?
      end

      def content_part_done(event)
        id = content_part_id(event.item_id, event.content_index)
        kind = @part_kinds.delete(id) || part_kind(item_type(event.part))
        @emitter.end_part(kind, id) if kind
      end

      def text_delta(event)
        id = content_part_id(event.item_id, event.content_index)
        @part_kinds[id] = :text
        @emitter.delta_part(:text, id, event.delta, provider_metadata: openai_metadata(item_id: event.item_id))
      end

      def text_done(event)
        id = content_part_id(event.item_id, event.content_index)
        @part_kinds.delete(id)
        @emitter.end_part(:text, id)
      end

      def reasoning_summary_added(event)
        id = reasoning_summary_id(event.item_id, event.summary_index)
        @part_kinds[id] = :reasoning
        @emitter.start_part(:reasoning, id, provider_metadata: openai_metadata(item_id: event.item_id))
        initial = event.part.text if event.part.respond_to?(:text)
        @emitter.delta_part(:reasoning, id, initial) if initial && !initial.empty?
      end

      def reasoning_summary_delta(event)
        id = reasoning_summary_id(event.item_id, event.summary_index)
        @part_kinds[id] = :reasoning
        @emitter.delta_part(:reasoning, id, event.delta,
                            provider_metadata: openai_metadata(item_id: event.item_id))
      end

      def reasoning_summary_done(event)
        id = reasoning_summary_id(event.item_id, event.summary_index)
        @part_kinds.delete(id)
        @emitter.end_part(:reasoning, id)
      end

      def reasoning_text_delta(event)
        id = content_part_id(event.item_id, event.content_index)
        @part_kinds[id] = :reasoning
        @emitter.delta_part(:reasoning, id, event.delta,
                            provider_metadata: openai_metadata(item_id: event.item_id))
      end

      def reasoning_text_done(event)
        id = content_part_id(event.item_id, event.content_index)
        @part_kinds.delete(id)
        @emitter.end_part(:reasoning, id)
      end

      def function_arguments_delta(event)
        tool = (@tools[event.item_id] ||= blank_tool(event.item_id))
        tool[:arguments] << event.delta
        return unless tool[:started]

        @emitter.event(:tool_input_delta, tool_call_id: tool[:id], input_text_delta: event.delta)
      end

      def function_arguments_done(event)
        tool = (@tools[event.item_id] ||= blank_tool(event.item_id))
        tool[:name] ||= event.name
        complete_tool(tool, event.arguments)
      end

      def output_item_done(event)
        item = event.item
        return unless item_type(item) == :function_call

        tool = register_tool(item.id, call_id: item.call_id, name: item.name)
        complete_tool(tool, item.arguments) unless tool[:finished]
      end

      def register_tool(item_id, call_id: nil, name: nil, arguments: nil)
        tool = (@tools[item_id] ||= blank_tool(item_id))
        tool[:id] = call_id if call_id && !call_id.empty?
        tool[:name] = name if name && !name.empty?
        start_tool(tool) if tool[:name] && !tool[:started]
        tool[:arguments] << arguments if arguments && !arguments.empty? && tool[:arguments].empty?
        tool
      end

      def start_tool(tool)
        @emitter.event(:tool_input_start, tool_call_id: tool[:id], tool_name: tool[:name],
                                          provider_metadata: openai_metadata(item_id: tool[:item_id]))
        tool[:started] = true
        @saw_tool_call = true
        return if tool[:arguments].empty?

        @emitter.event(:tool_input_delta, tool_call_id: tool[:id], input_text_delta: tool[:arguments])
      end

      def complete_tool(tool, arguments)
        tool[:arguments] = arguments unless arguments.nil? || arguments.empty?
        start_tool(tool) if tool[:name] && !tool[:started]
        raise Error, "OpenAI function call #{tool[:item_id].inspect} has no name" unless tool[:started]

        input = parse_json(tool[:arguments])
        @emitter.event(:tool_input_available, tool_call_id: tool[:id], tool_name: tool[:name], input: input,
                                              provider_metadata: openai_metadata(item_id: tool[:item_id]))
        tool[:finished] = true
      rescue JSON::ParserError => e
        @emitter.event(:tool_input_error, tool_call_id: tool[:id], tool_name: tool[:name],
                                          input: tool[:arguments], error_text: "invalid JSON tool input: #{e.message}",
                                          provider_metadata: openai_metadata(item_id: tool[:item_id]))
        tool[:finished] = true
      end

      def completed(event)
        @response = event.response
        finish
      end

      def incomplete(event)
        @response = event.response
        finish(finish_reason: incomplete_reason(@response))
      end

      def failed(event)
        @response = event.response
        finish_error(response_error(@response) || "OpenAI response failed")
      end

      def provider_error(event)
        finish_error(event.message)
      end

      def finish(finish_reason: nil)
        flush_tools
        @finish_reason = finish_reason || (@saw_tool_call ? :tool_calls : :stop)
        @emitter.finish(finish_reason: @finish_reason, message_metadata: response_metadata)
      end

      def finish_error(message)
        flush_tools
        @emitter.error(message)
      end

      def flush_tools
        @tools.each_value do |tool|
          next if tool[:finished]

          complete_tool(tool, tool[:arguments])
        end
      end

      def response_metadata
        return unless @response

        metadata = { provider: "openai", response_id: @response.id }
        metadata[:model] = @response.model.to_s if @response.respond_to?(:model) && @response.model
        metadata[:usage] = sdk_json(@response.usage) if @response.respond_to?(:usage) && @response.usage
        metadata
      end

      def response_error(response)
        return unless response.respond_to?(:error) && response.error

        response.error.respond_to?(:message) ? response.error.message : response.error.to_s
      end

      def incomplete_reason(response)
        details = response.incomplete_details if response.respond_to?(:incomplete_details)
        reason = details.reason.to_s if details.respond_to?(:reason)
        return :content_filter if reason == "content_filter"
        return :length if %w[max_output_tokens max_tokens].include?(reason)

        :other
      end

      def ignore_or_reject(event, type)
        return if type.to_s.start_with?(*IGNORED_EVENT_PREFIXES)
        return if type.to_s.start_with?("response.")

        raise UnsupportedEventError, "unsupported openai-ruby event #{event.class} (#{type.inspect})"
      end

      def blank_tool(item_id)
        { item_id: item_id, id: item_id, name: nil, arguments: +"", started: false, finished: false }
      end

      def item_type(item)
        item.respond_to?(:type) && item.type&.to_sym
      end

      def part_kind(type)
        return :text if %i[output_text refusal].include?(type)

        :reasoning if type == :reasoning_text
      end

      def content_part_id(item_id, content_index) = "#{item_id}:content:#{content_index}"
      def reasoning_summary_id(item_id, summary_index) = "#{item_id}:summary:#{summary_index}"
      def parse_json(text) = text.nil? || text.empty? ? {} : JSON.parse(text)

      def openai_metadata(item_id:)
        { openai: { item_id: item_id } }
      end

      def sdk_json(value)
        value = value.to_h if value.respond_to?(:to_h) && !value.is_a?(Hash)
        case value
        when nil, true, false, String, Integer, Float then value
        when Symbol then value.to_s
        when Array then value.map { |item| sdk_json(item) }
        when Hash then value.to_h { |key, item| [key.to_s, sdk_json(item)] }
        else raise Error, "unsupported OpenAI metadata value #{value.class}"
        end
      end
    end
    # rubocop:enable Metrics/ClassLength, Metrics/MethodLength, Metrics/AbcSize
    # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  end
end
