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

      def initialize(events, message_id: nil, finish_reason: :stop, id_generator: -> { SecureRandom.uuid },
                     lifecycle: :message)
        @events = events
        @message_id = message_id
        @finish_reason = finish_reason
        @id_generator = id_generator
        @lifecycle = lifecycle
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
        @emitter = Emitter.new(message_id: @message_id, consumer: consumer, lifecycle: @lifecycle)
        @tools = {}
        @tool_ids_by_stream_key = {}
        @latest_tool_id = nil
        @text_id = nil
        @reasoning_id = nil
        @model_id = nil
        @usage = {}
        @step_usage = nil
        @next_chunk_starts_step = false
        @observed_finish_reason = nil
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
        begin_next_step if @next_chunk_starts_step
        @emitter.start
        @model_id ||= chunk_model(chunk)
        @step_usage = chunk.tokens.to_h if chunk.tokens
        if chunk.respond_to?(:finish_reason) && chunk.finish_reason
          @observed_finish_reason = normalize_finish_reason(chunk.finish_reason)
        end
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
        return [content, []] if content.is_a?(String)

        if defined?(::RubyLLM::Content::Raw) && content.is_a?(::RubyLLM::Content::Raw)
          return [content.value, []] if content.value.is_a?(String)

          raise Error, "RubyLLM::Content::Raw cannot be mapped to text from #{content.value.class}"
        end

        if defined?(::RubyLLM::Content) && content.is_a?(::RubyLLM::Content)
          validate_attachments(content.attachments)
          return [content.text, content.attachments]
        end

        raise Error, "RubyLLM chunk content cannot be mapped to text from #{content.class}"
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
        @next_chunk_starts_step = true
      end

      def tool_result_value(content)
        return content.value if defined?(::RubyLLM::Content::Raw) && content.is_a?(::RubyLLM::Content::Raw)

        if defined?(::RubyLLM::Content) && content.is_a?(::RubyLLM::Content)
          return content.text if content.attachments.empty?

          raise Error, "RubyLLM tool-result attachments are not JSON-compatible outputs"
        end

        parse_json_container(content)
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
        commit_step_usage
        metadata = { provider: "ruby_llm" }
        metadata[:model] = @model_id if @model_id
        metadata[:usage] = @usage unless @usage.empty?
        @emitter.finish(finish_reason: @observed_finish_reason || @finish_reason, message_metadata: metadata)
      end

      def begin_next_step
        commit_step_usage
        @emitter.next_step
        @tool_ids_by_stream_key = {}
        @latest_tool_id = nil
        @text_id = nil
        @reasoning_id = nil
        @step_usage = nil
        @next_chunk_starts_step = false
      end

      def commit_step_usage
        return unless @step_usage

        @step_usage.each do |key, value|
          @usage[key] = @usage.fetch(key, 0) + value if value.is_a?(Numeric)
        end
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

      def chunk_model(chunk)
        return chunk.model_id if chunk.respond_to?(:model_id)
        return chunk.model if chunk.respond_to?(:model)

        nil
      end

      def normalize_finish_reason(reason)
        case reason.to_sym
        when :max_tokens then :length
        when :content_filter then :content_filter
        when :tool_calls then :tool_calls
        when :stop then :stop
        else :other
        end
      end

      def parse_json_container(value)
        return value unless value.is_a?(String) && ["{", "["].include?(value.lstrip[0])

        JSON.parse(value)
      rescue JSON::ParserError
        value
      end

      def parse_json(text) = text.empty? ? {} : JSON.parse(text)
      def next_id(prefix) = "#{prefix}-#{@id_generator.call}"
    end
    # rubocop:enable Metrics/ClassLength, Metrics/MethodLength, Metrics/AbcSize
    # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  end
end
