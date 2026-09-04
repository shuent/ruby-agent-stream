# frozen_string_literal: true

require "json"
require "anthropic"

require_relative "../adapters"

module AIStream
  module Adapters
    # Converts official anthropic-sdk-ruby Messages streaming events into
    # validated AI SDK UI Message Stream Protocol events.
    # rubocop:disable Metrics/ClassLength, Metrics/MethodLength, Metrics/AbcSize
    # rubocop:disable Metrics/CyclomaticComplexity
    class Anthropic
      include Enumerable

      HIGH_LEVEL_TYPES = %i[text input_json citation thinking signature compaction].freeze
      TOOL_TYPES = %i[tool_use server_tool_use mcp_tool_use].freeze

      def initialize(events, message_id: nil)
        @events = events
        @message_id = message_id
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
        @emitter = Emitter.new(message_id: @message_id, consumer: consumer)
        @blocks = {}
        @message = nil
        @usage = nil
        @stop_reason = nil
        @saw_tool_call = false
      end

      def dispatch(event)
        type = event_type(event)
        case type
        when :message_start then message_start(event)
        when :content_block_start then content_block_start(event)
        when :content_block_delta then content_block_delta(event)
        when :content_block_stop then content_block_stop(event)
        when :message_delta then message_delta(event)
        when :message_stop then message_stop(event)
        when *HIGH_LEVEL_TYPES then nil
        else
          raise UnsupportedEventError, "unsupported anthropic-sdk-ruby event #{event.class} (#{type.inspect})"
        end
      end

      def event_type(event)
        type = event.type if event.respond_to?(:type)
        return type.to_sym if type

        raise UnsupportedEventError, "expected an anthropic-sdk-ruby streaming event, got #{event.class}"
      end

      def message_start(event)
        @message = event.message
        @usage = sdk_json(@message.usage) if @message.respond_to?(:usage)
        @emitter.start(@message.id)
      end

      def content_block_start(event)
        block = event.content_block
        type = block.type.to_sym
        state = { type: type, id: block_id(event.index), signature: nil }
        @blocks[event.index] = state

        case type
        when :text
          @emitter.start_part(:text, state[:id], provider_metadata: anthropic_metadata(index: event.index))
          emit_initial_part(:text, state[:id], block, :text)
        when :thinking
          state[:signature] = block.signature if block.respond_to?(:signature)
          @emitter.start_part(:reasoning, state[:id], provider_metadata: anthropic_metadata(index: event.index))
          emit_initial_part(:reasoning, state[:id], block, :thinking)
        when *TOOL_TYPES
          start_tool(state, block, event.index)
        end
      end

      def emit_initial_part(kind, id, block, attribute)
        value = block.public_send(attribute) if block.respond_to?(attribute)
        @emitter.delta_part(kind, id, value) if value && !value.empty?
      end

      def start_tool(state, block, index)
        state[:id] = block.id
        state[:name] = block.name.to_s
        state[:input] = block.input if block.respond_to?(:input)
        state[:arguments] = +""
        state[:provider_executed] = state[:type] != :tool_use
        @emitter.event(:tool_input_start, tool_call_id: state[:id], tool_name: state[:name],
                                          provider_executed: state[:provider_executed],
                                          provider_metadata: anthropic_metadata(index: index))
        @saw_tool_call = true
      end

      def content_block_delta(event)
        delta = event.delta
        state = @blocks[event.index]
        type = delta.type.to_sym
        case type
        when :text_delta
          state ||= inferred_part(event.index, :text)
          @emitter.delta_part(:text, state[:id], delta.text,
                              provider_metadata: anthropic_metadata(index: event.index))
        when :thinking_delta
          state ||= inferred_part(event.index, :thinking)
          @emitter.delta_part(:reasoning, state[:id], delta.thinking,
                              provider_metadata: anthropic_metadata(index: event.index))
        when :signature_delta
          state ||= inferred_part(event.index, :thinking)
          state[:signature] = delta.signature
        when :input_json_delta
          tool = @blocks[event.index]
          raise Error, "Anthropic tool delta at index #{event.index} has no content block" unless tool

          tool[:arguments] << delta.partial_json
          @emitter.event(:tool_input_delta, tool_call_id: tool[:id], input_text_delta: delta.partial_json)
        when :citations_delta
          nil
        end
      end

      def content_block_stop(event)
        state = @blocks.delete(event.index)
        return unless state

        case state[:type]
        when :text
          @emitter.end_part(:text, state[:id])
        when :thinking
          metadata = state[:signature] ? { anthropic: { signature: state[:signature] } } : nil
          @emitter.end_part(:reasoning, state[:id], provider_metadata: metadata)
        when *TOOL_TYPES
          complete_tool(state, completed_block(event))
        end
      end

      def completed_block(event)
        event.content_block if event.respond_to?(:content_block)
      end

      def complete_tool(tool, block = nil)
        input = if !tool[:arguments].empty?
                  JSON.parse(tool[:arguments])
                elsif block.respond_to?(:input)
                  block.input
                else
                  tool[:input] || {}
                end
        @emitter.event(:tool_input_available, tool_call_id: tool[:id], tool_name: tool[:name], input: input,
                                              provider_executed: tool[:provider_executed])
        tool[:finished] = true
      rescue JSON::ParserError => e
        @emitter.event(:tool_input_error, tool_call_id: tool[:id], tool_name: tool[:name],
                                          input: tool[:arguments], error_text: "invalid JSON tool input: #{e.message}",
                                          provider_executed: tool[:provider_executed])
        tool[:finished] = true
      end

      def message_delta(event)
        @stop_reason = event.delta.stop_reason if event.delta.respond_to?(:stop_reason)
        @usage = sdk_json(event.usage) if event.respond_to?(:usage)
      end

      def message_stop(event)
        @message = event.message if event.respond_to?(:message)
        finish
      end

      def finish
        flush_tools
        @emitter.finish(finish_reason: finish_reason, message_metadata: message_metadata)
      end

      def flush_tools
        @blocks.each_value do |block|
          complete_tool(block) if TOOL_TYPES.include?(block[:type]) && !block[:finished]
        end
      end

      def finish_reason
        case @stop_reason&.to_sym
        when :max_tokens then :length
        when :tool_use then :tool_calls
        when :refusal then :content_filter
        when :end_turn, :stop_sequence, :pause_turn, nil then @saw_tool_call ? :tool_calls : :stop
        else :other
        end
      end

      def message_metadata
        metadata = { provider: "anthropic" }
        metadata[:message_id] = @message.id if @message.respond_to?(:id)
        metadata[:model] = @message.model.to_s if @message.respond_to?(:model) && @message.model
        metadata[:usage] = @usage if @usage
        metadata
      end

      def inferred_part(index, type)
        @blocks[index] = { type: type, id: block_id(index), signature: nil }
      end

      def block_id(index) = "anthropic:content:#{index}"

      def anthropic_metadata(index:)
        { anthropic: { content_block_index: index } }
      end

      def sdk_json(value)
        value = value.to_h if value.respond_to?(:to_h) && !value.is_a?(Hash)
        case value
        when nil, true, false, String, Integer, Float then value
        when Symbol then value.to_s
        when Array then value.map { |item| sdk_json(item) }
        when Hash then value.to_h { |key, item| [key.to_s, sdk_json(item)] }
        else raise Error, "unsupported Anthropic metadata value #{value.class}"
        end
      end
    end
    # rubocop:enable Metrics/ClassLength, Metrics/MethodLength, Metrics/AbcSize
    # rubocop:enable Metrics/CyclomaticComplexity
  end
end
