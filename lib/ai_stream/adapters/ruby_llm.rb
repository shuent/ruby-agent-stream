# frozen_string_literal: true

require "json"
require "securerandom"
require "ruby_llm"

require_relative "../adapters"

module AgentStream
  module Adapters
    # Converts RubyLLM chunks and tool-result messages into validated AI SDK UI
    # Message Stream Protocol events.
    # rubocop:disable Metrics/ClassLength, Metrics/MethodLength, Metrics/AbcSize
    # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    class RubyLLM
      include Enumerable

      def initialize(events, message_id: nil, finish_reason: :stop, id_generator: -> { SecureRandom.uuid })
        @events = events
        @message_id = message_id
        @finish_reason = finish_reason
        @id_generator = id_generator
      end

      def each(&consumer)
        return enum_for(:each) unless consumer

        reset(consumer)
        @events.each { |event| dispatch(event) }
        finish
        self
      end

      private

      def reset(consumer)
        @emitter = Emitter.new(message_id: @message_id, consumer: consumer)
        @tools = {}
        @tool_ids_by_stream_key = {}
        @latest_tool_id = nil
        @text_id = nil
        @reasoning_id = nil
        @model_id = nil
        @usage = nil
      end

      def dispatch(event)
        case event
        when ::RubyLLM::Chunk
          chunk(event)
        when ::RubyLLM::Message
          tool_result(event)
        else
          raise UnsupportedEventError, "expected RubyLLM::Chunk or tool-result Message, got #{event.class}"
        end
      end

      def chunk(chunk)
        @emitter.start
        @model_id ||= chunk.model_id
        @usage = chunk.tokens.to_h if chunk.tokens
        reasoning(chunk.thinking) if chunk.thinking
        content(chunk.content) unless chunk.content.nil? || chunk.content == ""
        tool_calls(chunk.tool_calls) if chunk.tool_call?
      end

      def reasoning(thinking)
        return if thinking.text.nil? || thinking.text.empty?

        @reasoning_id ||= next_id("reasoning")
        metadata = thinking.signature ? { ruby_llm: { thought_signature: thinking.signature } } : nil
        @emitter.delta_part(:reasoning, @reasoning_id, thinking.text, provider_metadata: metadata)
      end

      def content(content)
        text, attachments = normalize_content(content)
        unless text.nil? || text.empty?
          @text_id ||= next_id("text")
          @emitter.delta_part(:text, @text_id, text)
        end
        attachments.each do |attachment|
          @emitter.event(:file, url: attachment.source.to_s, media_type: attachment.mime_type)
        end
      end

      def normalize_content(content)
        case content
        when String
          [content, []]
        when ::RubyLLM::Content
          validate_attachments(content.attachments)
          [content.text, content.attachments]
        when ::RubyLLM::Content::Raw
          return [content.value, []] if content.value.is_a?(String)

          raise Error, "RubyLLM::Content::Raw cannot be mapped to text from #{content.value.class}"
        else
          raise Error, "RubyLLM chunk content cannot be mapped to text from #{content.class}"
        end
      end

      def validate_attachments(attachments)
        invalid = attachments.find { |attachment| !attachment.is_a?(::RubyLLM::Attachment) || !attachment.url? }
        return unless invalid

        raise Error, "only URL RubyLLM attachments can be mapped to UI message file events"
      end

      def tool_calls(calls)
        calls.each do |stream_key, call|
          if call.id && !call.id.empty? && @tools.key?(call.id)
            continue_tool(stream_key, call)
          elsif call.id && !call.id.empty?
            begin_tool(stream_key, call)
          else
            append_tool(stream_key, call)
          end
        end
      end

      def begin_tool(stream_key, call)
        id = call.id
        validate_binding(stream_key, id)
        metadata = call.thought_signature ? { ruby_llm: { thought_signature: call.thought_signature } } : nil
        attributes = { tool_call_id: id, tool_name: call.name }
        attributes[:provider_metadata] = metadata if metadata
        @emitter.event(:tool_input_start, **attributes)
        @tools[id] = { id: id, name: call.name, arguments: +"", structured_input: nil, finished: false }
        bind(stream_key, id)
        bind(call.id, id)
        @latest_tool_id = id
        append_arguments(@tools.fetch(id), call.arguments)
      end

      def continue_tool(stream_key, call)
        tool = @tools.fetch(call.id)
        raise Error, "RubyLLM tool #{call.id.inspect} changed its name" unless call.name == tool[:name]

        validate_binding(stream_key, call.id)
        bind(stream_key, call.id)
        @latest_tool_id = call.id
        append_arguments(tool, call.arguments)
      end

      def append_tool(stream_key, call)
        id = stream_key.nil? ? @latest_tool_id : @tool_ids_by_stream_key[stream_key]
        raise Error, "RubyLLM tool input fragment has no matching invocation" unless id

        tool = @tools.fetch(id)
        if call.name && call.name != tool[:name]
          raise Error, "RubyLLM tool input fragment changed the tool name for #{id.inspect}"
        end

        append_arguments(tool, call.arguments)
      end

      def append_arguments(tool, arguments)
        return if arguments.nil? || (arguments.respond_to?(:empty?) && arguments.empty?)

        if arguments.is_a?(Hash) || arguments.is_a?(Array)
          unless tool[:arguments].empty? && tool[:structured_input].nil?
            raise Error, "cannot append structured input to streamed JSON for RubyLLM tool #{tool[:id].inspect}"
          end

          tool[:structured_input] = arguments
        else
          fragment = arguments.to_s
          tool[:arguments] << fragment
          @emitter.event(:tool_input_delta, tool_call_id: tool[:id], input_text_delta: fragment)
        end
      end

      def tool_result(message)
        raise UnsupportedEventError, "expected a RubyLLM tool-result Message" unless message.tool_result?

        @emitter.start
        flush_tools
        unless @tools.key?(message.tool_call_id)
          raise Error, "RubyLLM tool result references unknown invocation #{message.tool_call_id.inspect}"
        end

        @emitter.event(:tool_output_available, tool_call_id: message.tool_call_id,
                                               output: tool_result_value(message.content))
      end

      def tool_result_value(content)
        case content
        when ::RubyLLM::Content::Raw then content.value
        when ::RubyLLM::Content
          return content.text if content.attachments.empty?

          raise Error, "RubyLLM tool-result attachments are not JSON-compatible outputs"
        else content
        end
      end

      def flush_tools
        @tools.each_value do |tool|
          next if tool[:finished]

          input = tool[:structured_input]
          input = parse_json(tool[:arguments]) if input.nil?
          @emitter.event(:tool_input_available, tool_call_id: tool[:id], tool_name: tool[:name], input: input)
          tool[:finished] = true
        rescue JSON::ParserError => e
          @emitter.event(
            :tool_input_error,
            tool_call_id: tool[:id],
            tool_name: tool[:name],
            input: tool[:arguments],
            error_text: "invalid JSON tool input: #{e.message}"
          )
          tool[:finished] = true
        end
      end

      def finish
        flush_tools
        metadata = { provider: "ruby_llm" }
        metadata[:model] = @model_id if @model_id
        metadata[:usage] = @usage if @usage
        @emitter.finish(finish_reason: @finish_reason, message_metadata: metadata)
      end

      def validate_binding(key, id)
        return if key.nil?

        existing = @tool_ids_by_stream_key[key]
        return if existing.nil? || existing == id

        raise Error, "RubyLLM tool stream key #{key.inspect} already identifies #{existing.inspect}"
      end

      def bind(key, id)
        @tool_ids_by_stream_key[key] = id unless key.nil?
      end

      def parse_json(text) = text.empty? ? {} : JSON.parse(text)
      def next_id(prefix) = "#{prefix}-#{@id_generator.call}"
    end
    # rubocop:enable Metrics/ClassLength, Metrics/MethodLength, Metrics/AbcSize
    # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  end
end
