# frozen_string_literal: true

require "json"
require "securerandom"
require "ruby_llm"

require_relative "../ui_message/v1"

module AgentStream
  module Adapters
    class Error < StandardError; end
    class UnsupportedEventError < Error; end

    # Feed chunks from ask and completed messages from after_message, in order.
    # RubyLLM owns tool execution and continuation; only completed tool inputs
    # are displayed. Text/thinking stay streamed, with UI boundaries added here.
    # Keep the event mapping and SDK version differences visible in one place.
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

        @consumer = consumer
        @parts = {}
        @message_complete = false
        @metadata = { provider: "ruby_llm" }
        @usage = {}
        @observed_finish_reason = nil
        emit(:start, **(@message_id ? { message_id: @message_id } : {}))
        emit(:start_step)
        dispatch_error = nil
        begin
          @events.each do |event|
            dispatch(event)
          rescue StandardError => e
            dispatch_error = e
            raise
          end
        rescue StandardError => e
          # Source failures become UI errors; invalid input and sink failures
          # must still reach the caller.
          raise if e.equal?(dispatch_error)

          close_parts
          emit(:finish_step)
          emit(:error, error_text: e.message)
          return self
        end
        close_parts
        emit(:finish_step)
        @metadata[:usage] = @usage unless @usage.empty?
        emit(:finish, finish_reason: @observed_finish_reason || @finish_reason, message_metadata: @metadata)
        self
      end

      private

      def dispatch(event)
        case event
        when ::RubyLLM::Chunk
          next_step if @message_complete
          delta(:reasoning, event.thinking.text, signature: event.thinking.signature) if event.thinking
          content(event.content) unless event.content.nil?
        when ::RubyLLM::Message
          if event.tool_result?
            emit(:tool_output_available, tool_call_id: event.tool_call_id, output: tool_result_value(event.content))
          elsif event.role == :assistant
            completed_message(event)
          else
            raise UnsupportedEventError, "expected an assistant or tool-result Message, got #{event.role}"
          end
        else
          raise UnsupportedEventError, "expected RubyLLM::Chunk or Message, got #{event.class}"
        end
      end

      def completed_message(message)
        next_step if @message_complete
        close_parts
        message.tool_calls&.each_value do |call|
          emit(:tool_input_available, tool_call_id: call.id, tool_name: call.name,
                                      input: call.arguments, **signature_metadata(call.thought_signature))
        end
        model = message.respond_to?(:model_id) ? message.model_id : message.model
        @metadata[:model] = model if model
        message.tokens&.to_h&.each do |key, value|
          @usage[key] = @usage.fetch(key, 0) + value if value.is_a?(Numeric)
        end
        reason = message.finish_reason if message.respond_to?(:finish_reason)
        @observed_finish_reason = normalize_finish_reason(reason)
        @message_complete = true
      end

      def next_step
        emit(:finish_step)
        emit(:start_step)
        @message_complete = false
        @observed_finish_reason = nil
      end

      def delta(kind, text, signature: nil)
        return if text.nil? || text.empty?

        unless @parts.key?(kind)
          @parts[kind] = "#{kind}-#{@id_generator.call}"
          emit(:"#{kind}_start", id: @parts[kind])
        end
        emit(:"#{kind}_delta", id: @parts[kind], delta: text, **signature_metadata(signature))
      end

      def close_parts
        @parts.each { |kind, id| emit(:"#{kind}_end", id: id) }
        @parts.clear
      end

      def content(value)
        case value
        when String
          delta(:text, value)
        else
          text, attachments = normalize_content(value)
          delta(:text, text)
          attachments.each { |file| emit(:file, url: file.source.to_s, media_type: file.mime_type) }
        end
      end

      def normalize_content(content)
        if defined?(::RubyLLM::Content::Raw) && content.is_a?(::RubyLLM::Content::Raw)
          return [content.value, []] if content.value.is_a?(String)

          raise Error, "RubyLLM::Content::Raw cannot be mapped to text from #{content.value.class}"
        end

        if defined?(::RubyLLM::Content) && content.is_a?(::RubyLLM::Content)
          unless content.attachments.all? { |file| file.is_a?(::RubyLLM::Attachment) && file.url? }
            raise Error, "only URL RubyLLM attachments can be mapped to UI message file events"
          end

          return [content.text, content.attachments]
        end

        raise Error, "RubyLLM chunk content cannot be mapped to text from #{content.class}"
      end

      def tool_result_value(content)
        return content.value if defined?(::RubyLLM::Content::Raw) && content.is_a?(::RubyLLM::Content::Raw)

        if defined?(::RubyLLM::Content) && content.is_a?(::RubyLLM::Content)
          return content.text if content.attachments.empty?

          raise Error, "RubyLLM tool-result attachments are not JSON-compatible outputs"
        end

        return content unless content.is_a?(String) && ["{", "["].include?(content.lstrip[0])

        JSON.parse(content)
      rescue JSON::ParserError
        content
      end

      def normalize_finish_reason(reason)
        return unless reason

        { max_tokens: :length, content_filter: :content_filter, tool_calls: :tool_calls,
          stop: :stop }.fetch(reason.to_sym, :other)
      end

      def signature_metadata(signature)
        signature ? { provider_metadata: { ruby_llm: { thought_signature: signature } } } : {}
      end

      def emit(type, **attributes)
        @consumer.call(UIMessage::V1::Event.new(type, **attributes))
      end
    end
    # rubocop:enable Metrics/ClassLength, Metrics/MethodLength, Metrics/AbcSize
    # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  end
end
