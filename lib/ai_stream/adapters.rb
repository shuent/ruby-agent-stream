# frozen_string_literal: true

require_relative "ui_message/v1"

module AgentStream
  # Provider SDK event adapters. Each adapter yields validated UIMessage events
  # and has no dependency on UIMessage::V1::Stream.
  module Adapters
    class Error < StandardError; end
    class UnsupportedEventError < Error; end

    # Shared protocol lifecycle and content-part bookkeeping for adapters.
    # Provider-specific event interpretation remains in each adapter.
    class Emitter
      LIFECYCLES = %i[message step content].freeze

      def initialize(message_id:, consumer:, lifecycle: :message)
        unless LIFECYCLES.include?(lifecycle)
          raise ArgumentError, "lifecycle must be one of #{LIFECYCLES.map(&:inspect).join(", ")}"
        end

        @message_id = message_id
        @consumer = consumer
        @lifecycle = lifecycle
        @started = false
        @finished = false
        @parts = {}
      end

      def started? = @started
      def finished? = @finished
      def part_open?(kind, id) = @parts[[kind, id]]

      def start(message_id = nil, message_metadata: nil)
        return if started?

        start_message(message_id, message_metadata) if message_lifecycle?
        consume(:start_step) if step_lifecycle?
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

      def next_step
        start
        close_parts
        return unless step_lifecycle?

        consume(:finish_step)
        consume(:start_step)
      end

      def finish(finish_reason: nil, message_metadata: nil)
        return if finished?

        start
        close_parts
        consume(:message_metadata, message_metadata: message_metadata) if content_metadata?(message_metadata)
        consume(:finish_step) if step_lifecycle?
        finish_message(finish_reason, message_metadata) if message_lifecycle?
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

      def message_lifecycle? = @lifecycle == :message
      def step_lifecycle? = @lifecycle != :content
      def content_metadata?(message_metadata) = !message_lifecycle? && message_metadata

      def start_message(message_id, message_metadata)
        attributes = {}
        attributes[:message_id] = message_id || @message_id if message_id || @message_id
        attributes[:message_metadata] = message_metadata if message_metadata
        consume(:start, **attributes)
      end

      def finish_message(finish_reason, message_metadata)
        attributes = {}
        attributes[:finish_reason] = finish_reason if finish_reason
        attributes[:message_metadata] = message_metadata if message_metadata
        consume(:finish, **attributes)
      end

      def consume(type, **attributes)
        @consumer.call(UIMessage::V1::Event.new(type, **attributes))
      end
    end
  end
end
