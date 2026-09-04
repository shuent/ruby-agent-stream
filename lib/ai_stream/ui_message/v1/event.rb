# frozen_string_literal: true

module AgentStream
  module UIMessage
    module V1
      # A validated, provider-neutral AI SDK UI Message Stream Protocol event.
      # The protocol has a deliberately broad event surface. Its declarative
      # schema and validators are clearer together than split by metric limits.
      # rubocop:disable Metrics/ClassLength, Metrics/MethodLength, Metrics/AbcSize
      # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      class Event
        JSON_VALUE = Object.new.freeze
        JSON_OBJECT = Object.new.freeze
        PROVIDER_METADATA = Object.new.freeze
        BOOLEAN = Object.new.freeze
        FINISH_REASON = Object.new.freeze

        FINISH_REASONS = %w[stop length content-filter tool-calls error other].freeze

        FIELD_NAMES = {
          message_id: "messageId",
          message_metadata: "messageMetadata",
          provider_metadata: "providerMetadata",
          source_id: "sourceId",
          media_type: "mediaType",
          finish_reason: "finishReason",
          error_text: "errorText",
          tool_call_id: "toolCallId",
          tool_name: "toolName",
          input_text_delta: "inputTextDelta",
          provider_executed: "providerExecuted",
          tool_metadata: "toolMetadata",
          approval_id: "approvalId",
          approval_descriptor: "approvalDescriptor",
          is_automatic: "isAutomatic"
        }.freeze

        TOOL_OPTIONS = {
          provider_executed: BOOLEAN,
          provider_metadata: PROVIDER_METADATA,
          tool_metadata: JSON_OBJECT,
          dynamic: BOOLEAN,
          title: String
        }.freeze

        SCHEMAS = {
          start: [{}, { message_id: String, message_metadata: JSON_VALUE }],
          start_step: [{}, {}],
          reset_step: [{}, {}],
          finish_step: [{}, {}],
          finish: [{}, { finish_reason: FINISH_REASON, message_metadata: JSON_VALUE }],
          abort: [{}, { reason: String }],
          error: [{ error_text: String }, {}],
          message_metadata: [{ message_metadata: JSON_VALUE }, {}],
          text_start: [{ id: String }, { provider_metadata: PROVIDER_METADATA }],
          text_delta: [{ id: String, delta: String }, { provider_metadata: PROVIDER_METADATA }],
          text_end: [{ id: String }, { provider_metadata: PROVIDER_METADATA }],
          reasoning_start: [{ id: String }, { provider_metadata: PROVIDER_METADATA }],
          reasoning_delta: [{ id: String, delta: String }, { provider_metadata: PROVIDER_METADATA }],
          reasoning_end: [{ id: String }, { provider_metadata: PROVIDER_METADATA }],
          source_url: [
            { source_id: String, url: String },
            { title: String, provider_metadata: PROVIDER_METADATA }
          ],
          source_document: [
            { source_id: String, media_type: String, title: String },
            { filename: String, provider_metadata: PROVIDER_METADATA }
          ],
          file: [{ url: String, media_type: String }, { provider_metadata: PROVIDER_METADATA }],
          reasoning_file: [{ url: String, media_type: String }, { provider_metadata: PROVIDER_METADATA }],
          data: [{ name: String, data: JSON_VALUE }, { id: String, transient: BOOLEAN }],
          custom: [{ kind: String }, { provider_metadata: PROVIDER_METADATA }],
          tool_input_start: [
            { tool_call_id: String, tool_name: String },
            TOOL_OPTIONS
          ],
          tool_input_delta: [{ tool_call_id: String, input_text_delta: String }, {}],
          tool_input_available: [
            { tool_call_id: String, tool_name: String, input: JSON_VALUE },
            TOOL_OPTIONS
          ],
          tool_input_error: [
            { tool_call_id: String, tool_name: String, input: JSON_VALUE, error_text: String },
            TOOL_OPTIONS
          ],
          tool_approval_request: [
            { approval_id: String, tool_call_id: String },
            { approval_descriptor: JSON_VALUE, reason: String, is_automatic: BOOLEAN, signature: String }
          ],
          tool_approval_response: [
            { approval_id: String, approved: BOOLEAN },
            { reason: String, provider_executed: BOOLEAN, provider_metadata: PROVIDER_METADATA }
          ],
          tool_output_available: [
            { tool_call_id: String, output: JSON_VALUE },
            TOOL_OPTIONS.merge(preliminary: BOOLEAN)
          ],
          tool_output_error: [
            { tool_call_id: String, error_text: String },
            TOOL_OPTIONS.except(:title).freeze
          ],
          tool_output_denied: [{ tool_call_id: String }, {}]
        }.transform_values { |required, optional| [required.freeze, optional.freeze].freeze }.freeze

        class Error < ArgumentError; end
        class UnknownTypeError < Error; end
        class SchemaError < Error; end
        class JSONCompatibilityError < SchemaError; end

        attr_reader :type, :attributes

        def initialize(type, **attributes)
          @type = normalize_type(type)
          @attributes = validate_attributes(attributes).freeze
          validate_semantics!
          freeze
        end

        def [](name) = attributes.fetch(name)

        def to_h
          event = { "type" => wire_type }
          attributes.each do |name, value|
            next if type == :data && name == :name

            event[FIELD_NAMES.fetch(name, name.to_s)] = value
          end
          event.freeze
        end

        private

        def normalize_type(type)
          normalized = type.is_a?(String) ? type.tr("-", "_").to_sym : type
          return normalized if normalized.is_a?(Symbol) && SCHEMAS.key?(normalized)

          raise UnknownTypeError, "unknown UI message event type #{type.inspect}"
        end

        def validate_attributes(attributes)
          required, optional = SCHEMAS.fetch(type)
          missing = required.keys - attributes.keys
          unknown = attributes.keys - required.keys - optional.keys
          raise SchemaError, "#{type} is missing #{missing.map(&:inspect).join(", ")}" unless missing.empty?
          raise SchemaError, "#{type} has unknown attributes #{unknown.map(&:inspect).join(", ")}" unless unknown.empty?

          attributes.to_h do |name, value|
            expected = required.fetch(name) { optional.fetch(name) }
            [name, normalize_value(value, expected, name.to_s)]
          end
        end

        def normalize_value(value, expected, path)
          case expected
          when JSON_VALUE then json_value(value, path)
          when JSON_OBJECT then json_object(value, path)
          when PROVIDER_METADATA then provider_metadata(value, path)
          when BOOLEAN then boolean(value, path)
          when FINISH_REASON then finish_reason(value)
          else
            return value.dup.freeze if expected == String && value.is_a?(String)
            return value if value.is_a?(expected)

            raise SchemaError, "#{path} must be a #{expected}"
          end
        end

        def json_value(value, path)
          case value
          when nil, true, false, Integer
            value
          when String
            value.dup.freeze
          when Float
            raise JSONCompatibilityError, "#{path} contains a non-finite number" unless value.finite?

            value
          when Array
            value.each_with_index.map { |item, index| json_value(item, "#{path}[#{index}]") }.freeze
          when Hash
            value.each_with_object({}) do |(key, item), result|
              unless key.is_a?(String) || key.is_a?(Symbol)
                raise JSONCompatibilityError, "#{path} contains a non-string key #{key.inspect}"
              end

              result[key.to_s.freeze] = json_value(item, "#{path}.#{key}")
            end.freeze
          else
            raise JSONCompatibilityError, "#{path} contains unsupported #{value.class}"
          end
        end

        def json_object(value, path)
          normalized = json_value(value, path)
          return normalized if normalized.is_a?(Hash)

          raise JSONCompatibilityError, "#{path} must be a JSON object"
        end

        def provider_metadata(value, path)
          normalized = json_object(value, path)
          return normalized if normalized.values.all?(Hash)

          raise JSONCompatibilityError, "#{path} values must be JSON objects"
        end

        def boolean(value, path)
          return value if [true, false].include?(value)

          raise SchemaError, "#{path} must be true or false"
        end

        def finish_reason(value)
          normalized = value.to_s.tr("_", "-")
          return normalized.freeze if FINISH_REASONS.include?(normalized)

          raise SchemaError, "finish_reason must be one of #{FINISH_REASONS.join(", ")}"
        end

        def validate_semantics!
          validate_nonempty!(:id) if attributes.key?(:id)
          validate_nonempty!(:source_id) if attributes.key?(:source_id)
          validate_nonempty!(:tool_call_id) if attributes.key?(:tool_call_id)
          validate_nonempty!(:approval_id) if attributes.key?(:approval_id)
          validate_nonempty!(:message_id) if attributes.key?(:message_id)
          validate_nonempty!(:name) if type == :data

          return unless type == :custom
          return if attributes.fetch(:kind).match?(/\A[^.]+\.[^.]+(?:\..+)?\z/)

          raise SchemaError, "kind must contain a namespace and name separated by a dot"
        end

        def validate_nonempty!(name)
          raise SchemaError, "#{name} must not be empty" if attributes.fetch(name).empty?
        end

        def wire_type
          return "data-#{attributes.fetch(:name)}" if type == :data

          type.to_s.tr("_", "-")
        end
      end
      # rubocop:enable Metrics/ClassLength, Metrics/MethodLength, Metrics/AbcSize
      # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    end
  end
end
