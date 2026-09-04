# frozen_string_literal: true

require_relative "ui_message/v1"

module AIStream
  # Provider SDK event adapters. Each adapter yields validated UIMessage events
  # and has no dependency on UIMessage::V1::Stream.
  module Adapters
    class Error < StandardError; end
    class UnsupportedEventError < Error; end

    # Shared protocol lifecycle and content-part bookkeeping for adapters.
    # Provider-specific event interpretation remains in each adapter.
    class Emitter
      def initialize(message_id:, consumer:)
        @message_id = message_id
        @consumer = consumer
        @started = false
        @finished = false
        @parts = {}
      end

      def started? = @started
      def finished? = @finished
      def part_open?(kind, id) = @parts[[kind, id]]

      def start(message_id = nil, message_metadata: nil)
        return if started?

        attributes = {}
        attributes[:message_id] = message_id || @message_id if message_id || @message_id
        attributes[:message_metadata] = message_metadata if message_metadata
        consume(:start, **attributes)
        consume(:start_step)
        @started = true
      end

      def event(type, **attributes)
        start
        consume(type, **attributes)
      end

      def start_part(kind, id, provider_metadata: nil)
        start
        return if part_open?(kind, id)

        attributes = { id: id }
        attributes[:provider_metadata] = provider_metadata if provider_metadata
        consume(:"#{kind}_start", **attributes)
        @parts[[kind, id]] = true
      end

      def delta_part(kind, id, delta, provider_metadata: nil)
        start_part(kind, id, provider_metadata: provider_metadata)
        attributes = { id: id, delta: delta }
        attributes[:provider_metadata] = provider_metadata if provider_metadata
        consume(:"#{kind}_delta", **attributes)
      end

      def end_part(kind, id, provider_metadata: nil)
        return unless part_open?(kind, id)

        attributes = { id: id }
        attributes[:provider_metadata] = provider_metadata if provider_metadata
        consume(:"#{kind}_end", **attributes)
        @parts.delete([kind, id])
      end

      def close_parts
        @parts.each_key { |kind, id| end_part(kind, id) }
      end

      def finish(finish_reason: nil, message_metadata: nil)
        return if finished?

        start
        close_parts
        consume(:finish_step)
        attributes = {}
        attributes[:finish_reason] = finish_reason if finish_reason
        attributes[:message_metadata] = message_metadata if message_metadata
        consume(:finish, **attributes)
        @finished = true
      end

      def error(error_text)
        return if finished?

        start
        close_parts
        consume(:finish_step)
        consume(:error, error_text: error_text)
        @finished = true
      end

      private

      def consume(type, **attributes)
        @consumer.call(UIMessage::V1::Event.new(type, **attributes))
      end
    end
  end
end
