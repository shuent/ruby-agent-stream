# frozen_string_literal: true

require "json"
require "securerandom"
require "ruby_llm"

require_relative "ai_sdk/version"

module RubyLLM
  module Stream
    # Converts RubyLLM chunks to AI SDK UI Message Stream Protocol v1 events.
    # The protocol's broad typed surface makes compact metric limits misleading;
    # sequence and shape tests cover these methods instead.
    # rubocop:disable Metrics/ClassLength, Metrics/MethodLength, Metrics/AbcSize
    # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/ParameterLists
    class AISDK
      include Enumerable

      HEADERS = {
        "content-type" => "text/event-stream",
        "cache-control" => "no-cache",
        "connection" => "keep-alive",
        "x-vercel-ai-ui-message-stream" => "v1",
        "x-accel-buffering" => "no"
      }.freeze
      FINISH_REASONS = %w[stop length content-filter tool-calls error other].freeze

      class Error < StandardError; end
      class ProtocolError < Error; end
      class FinishedError < Error; end
      class JSONCompatibilityError < Error; end

      attr_reader :frames

      def self.headers
        HEADERS.dup
      end

      def initialize(io = nil, message_id: nil, id_generator: -> { SecureRandom.uuid })
        @io = io
        @message_id = message_id
        @id_generator = id_generator
        @frames = []
        @started = false
        @step_active = false
        @finished = false
        @text_parts = {}
        @reasoning_parts = {}
        @tools = {}
        @approvals = {}
        @tool_ids_by_stream_key = {}
        @latest_tool_id = nil
        @step_generation = 0
      end

      def headers = self.class.headers
      def to_a = frames.dup
      def started? = @started
      def finished? = @finished

      def each(&block)
        return enum_for(:each) unless block

        frames.each(&block)
        self
      end

      def start(message_id: @message_id, message_metadata: nil)
        ensure_writable!
        raise ProtocolError, "the stream has already started" if @started

        event = { type: "start" }
        event[:messageId] = require_string!(message_id, :message_id) unless message_id.nil?
        event[:messageMetadata] = json_value(message_metadata) unless message_metadata.nil?
        emit(event)
        @started = true
        self
      end

      def start_step
        ensure_writable!
        ensure_started!
        raise ProtocolError, "a step is already active" if @step_active

        emit(type: "start-step")
        @step_active = true
        @step_generation += 1
        self
      end

      def reset_step
        ensure_writable!
        require_active_step!
        clear_current_step_state
        emit(type: "reset-step")
        self
      end

      def finish_step
        ensure_writable!
        require_active_step!
        close_open_parts
        flush_tool_inputs
        emit(type: "finish-step")
        @step_active = false
        @tool_ids_by_stream_key.clear
        @latest_tool_id = nil
        self
      end

      def finish(finish_reason: nil, message_metadata: nil)
        ensure_writable!
        ensure_started!
        start_step unless @step_active || @step_generation.positive?
        finish_step if @step_active

        event = { type: "finish" }
        event[:finishReason] = normalize_finish_reason(finish_reason) unless finish_reason.nil?
        event[:messageMetadata] = json_value(message_metadata) unless message_metadata.nil?
        emit(event)
        terminate!
        self
      end

      def abort(reason: nil)
        ensure_writable!
        ensure_active_step!
        finish_step
        event = { type: "abort" }
        event[:reason] = require_string!(reason, :reason) unless reason.nil?
        emit(event)
        terminate!
        self
      end

      def error(error_text:)
        ensure_writable!
        ensure_active_step!
        finish_step
        emit(type: "error", errorText: require_string!(error_text, :error_text))
        terminate!
        self
      end

      def message_metadata(metadata)
        ensure_active_step!
        emit(type: "message-metadata", messageMetadata: json_value(metadata))
        self
      end

      def write(chunk)
        ensure_writable!
        raise ArgumentError, "expected RubyLLM::Chunk, got #{chunk.class}" unless chunk.is_a?(RubyLLM::Chunk)

        ensure_active_step!
        write_reasoning(chunk.thinking) if chunk.thinking
        write_content(chunk.content) unless chunk.content.nil? || chunk.content == ""
        write_tool_calls(chunk.tool_calls) if chunk.tool_call?
        self
      end
      alias push write

      def <<(chunk)
        write(chunk)
        self
      end

      def write_message(message)
        ensure_writable!
        raise ArgumentError, "expected RubyLLM::Message, got #{message.class}" unless message.is_a?(RubyLLM::Message)
        raise ArgumentError, "expected a RubyLLM tool-result message" unless message.tool_result?

        ensure_active_step!
        # RubyLLM delivers tool-result messages after the assistant's streamed
        # tool calls, but it does not emit a separate "arguments complete"
        # chunk. Complete every call from this step before the first result so
        # parallel tool invocations keep the protocol's input-before-output
        # ordering.
        flush_tool_inputs
        tool_output_available(tool_call_id: message.tool_call_id, output: message.content)
      end

      def text_start(id: next_id("text"), provider_metadata: nil)
        ensure_active_step!
        id = require_id!(id)
        raise ProtocolError, "text part #{id.inspect} has already started" if @text_parts.key?(id)

        provider_metadata = provider_metadata(provider_metadata) unless provider_metadata.nil?
        @text_parts[id] = @step_generation
        emit_optional({ type: "text-start", id: id }, providerMetadata: provider_metadata)
        self
      end

      def text_delta(id:, delta:, provider_metadata: nil)
        ensure_active_step!
        id = require_id!(id)
        require_part!(@text_parts, id, "text")
        emit_optional({ type: "text-delta", id: id, delta: require_string!(delta, :delta) },
                      providerMetadata: provider_metadata)
        self
      end

      def text_end(id:, provider_metadata: nil)
        ensure_active_step!
        id = require_id!(id)
        require_part!(@text_parts, id, "text")
        emit_optional({ type: "text-end", id: id }, providerMetadata: provider_metadata)
        @text_parts.delete(id)
        self
      end

      def reasoning_start(id: next_id("reasoning"), provider_metadata: nil)
        ensure_active_step!
        id = require_id!(id)
        raise ProtocolError, "reasoning part #{id.inspect} has already started" if @reasoning_parts.key?(id)

        provider_metadata = provider_metadata(provider_metadata) unless provider_metadata.nil?
        @reasoning_parts[id] = @step_generation
        emit_optional({ type: "reasoning-start", id: id }, providerMetadata: provider_metadata)
        self
      end

      def reasoning_delta(id:, delta:, provider_metadata: nil)
        ensure_active_step!
        id = require_id!(id)
        require_part!(@reasoning_parts, id, "reasoning")
        emit_optional({ type: "reasoning-delta", id: id, delta: require_string!(delta, :delta) },
                      providerMetadata: provider_metadata)
        self
      end

      def reasoning_end(id:, provider_metadata: nil)
        ensure_active_step!
        id = require_id!(id)
        require_part!(@reasoning_parts, id, "reasoning")
        emit_optional({ type: "reasoning-end", id: id }, providerMetadata: provider_metadata)
        @reasoning_parts.delete(id)
        self
      end

      def source_url(source_id:, url:, title: nil, provider_metadata: nil)
        ensure_active_step!
        emit_optional({ type: "source-url", sourceId: require_id!(source_id), url: require_string!(url, :url) },
                      title: title, providerMetadata: provider_metadata)
        self
      end

      def source_document(source_id:, media_type:, title:, filename: nil, provider_metadata: nil)
        ensure_active_step!
        emit_optional({
                        type: "source-document", sourceId: require_id!(source_id),
                        mediaType: require_string!(media_type, :media_type), title: require_string!(title, :title)
                      }, filename: filename, providerMetadata: provider_metadata)
        self
      end

      def file(url:, media_type:, provider_metadata: nil)
        ensure_active_step!
        emit_optional({ type: "file", url: require_string!(url, :url),
                        mediaType: require_string!(media_type, :media_type) },
                      providerMetadata: provider_metadata)
        self
      end

      def reasoning_file(url:, media_type:, provider_metadata: nil)
        ensure_active_step!
        emit_optional({ type: "reasoning-file", url: require_string!(url, :url),
                        mediaType: require_string!(media_type, :media_type) },
                      providerMetadata: provider_metadata)
        self
      end

      def data(name:, data:, id: nil, transient: nil)
        ensure_active_step!
        name = require_string!(name, :name)
        raise ArgumentError, "name must not be empty" if name.empty?

        emit_optional({ type: "data-#{name}", data: json_value(data) }, id: id, transient: transient)
        self
      end

      def custom(kind:, provider_metadata: nil)
        ensure_active_step!
        kind = require_string!(kind, :kind)
        unless kind.match?(/\A[^.]+\.[^.]+(?:\..+)?\z/)
          raise ArgumentError, "kind must contain a namespace and name separated by a dot"
        end

        emit_optional({ type: "custom", kind: kind }, providerMetadata: provider_metadata)
        self
      end

      def tool_input_start(tool_call_id:, tool_name:, provider_executed: nil, provider_metadata: nil,
                           tool_metadata: nil, dynamic: nil, title: nil)
        ensure_active_step!
        id = require_id!(tool_call_id)
        raise ProtocolError, "tool invocation #{id.inspect} already exists" if @tools.key?(id)

        options = tool_options(provider_executed:, provider_metadata:, tool_metadata:, dynamic:, title:)
        @tools[id] = {
          name: require_string!(tool_name, :tool_name), state: :input_streaming,
          input_text: +"", structured_input: nil, options: options, step: @step_generation
        }
        emit_optional({ type: "tool-input-start", toolCallId: id, toolName: @tools[id][:name] }, **options)
        self
      end

      def tool_input_delta(tool_call_id:, input_text_delta:)
        ensure_active_step!
        id = require_id!(tool_call_id)
        tool = require_tool!(id)
        require_tool_state!(tool, id, :input_streaming)
        delta = require_string!(input_text_delta, :input_text_delta)
        raise ProtocolError, "tool invocation #{id.inspect} has structured input" if tool[:structured_input]

        tool[:input_text] << delta
        emit(type: "tool-input-delta", toolCallId: id, inputTextDelta: delta)
        self
      end

      def tool_input_available(tool_call_id:, tool_name:, input:, provider_executed: nil, provider_metadata: nil,
                               tool_metadata: nil, dynamic: nil, title: nil)
        ensure_active_step!
        id = require_id!(tool_call_id)
        options = tool_options(provider_executed:, provider_metadata:, tool_metadata:, dynamic:, title:)
        input = json_value(input)
        tool = register_or_require_streaming_tool(id, tool_name, options)
        emit_optional({ type: "tool-input-available", toolCallId: id, toolName: tool[:name],
                        input: input }, **merged_tool_options(tool, options))
        tool[:state] = :input_available
        self
      end

      def tool_input_error(tool_call_id:, tool_name:, input:, error_text:, provider_executed: nil,
                           provider_metadata: nil, tool_metadata: nil, dynamic: nil, title: nil)
        ensure_active_step!
        id = require_id!(tool_call_id)
        options = tool_options(provider_executed:, provider_metadata:, tool_metadata:, dynamic:, title:)
        input = json_value(input)
        tool = register_or_require_streaming_tool(id, tool_name, options)
        emit_optional({ type: "tool-input-error", toolCallId: id, toolName: tool[:name],
                        input: input, errorText: require_string!(error_text, :error_text) },
                      **merged_tool_options(tool, options))
        tool[:state] = :input_error
        self
      end

      def tool_approval_request(approval_id:, tool_call_id:, approval_descriptor: nil, reason: nil,
                                is_automatic: nil, signature: nil)
        ensure_active_step!
        id = require_id!(tool_call_id)
        tool = require_tool!(id)
        unless %i[input_available output_preliminary].include?(tool[:state])
          raise ProtocolError, "tool invocation #{id.inspect} is not ready for approval"
        end

        approval_id = require_id!(approval_id)
        raise ProtocolError, "approval #{approval_id.inspect} already exists" if @approvals.key?(approval_id)

        emit_optional({ type: "tool-approval-request", approvalId: approval_id, toolCallId: id },
                      approvalDescriptor: approval_descriptor, reason: reason,
                      isAutomatic: is_automatic, signature: signature)
        @approvals[approval_id] = { tool_call_id: id, responded: false }
        tool[:state] = :approval_requested
        self
      end

      def tool_approval_response(approval_id:, approved:, reason: nil, provider_executed: nil,
                                 provider_metadata: nil)
        ensure_active_step!
        approval_id = require_id!(approval_id)
        approval = @approvals[approval_id]
        raise ProtocolError, "approval #{approval_id.inspect} has not been requested" unless approval
        raise ProtocolError, "approval #{approval_id.inspect} has already been answered" if approval[:responded]

        approved = require_boolean!(approved, :approved)
        emit_optional({ type: "tool-approval-response", approvalId: approval_id, approved: approved },
                      reason: reason, providerExecuted: provider_executed, providerMetadata: provider_metadata)
        approval[:responded] = true
        @tools.fetch(approval[:tool_call_id])[:state] = approved ? :approval_approved : :approval_denied
        self
      end

      def tool_output_available(tool_call_id:, output:, provider_executed: nil, provider_metadata: nil,
                                tool_metadata: nil, dynamic: nil, preliminary: nil)
        ensure_active_step!
        id = require_id!(tool_call_id)
        tool = require_tool_for_output!(id)
        preliminary = require_boolean!(preliminary, :preliminary) unless preliminary.nil?
        emit_optional({ type: "tool-output-available", toolCallId: id, output: json_value(output) },
                      providerExecuted: provider_executed, providerMetadata: provider_metadata,
                      toolMetadata: tool_metadata, dynamic: dynamic, preliminary: preliminary)
        tool[:state] = preliminary ? :output_preliminary : :output_available
        self
      end

      def tool_output_error(tool_call_id:, error_text:, provider_executed: nil, provider_metadata: nil,
                            tool_metadata: nil, dynamic: nil)
        ensure_active_step!
        id = require_id!(tool_call_id)
        tool = require_tool_for_output!(id)
        emit_optional({ type: "tool-output-error", toolCallId: id,
                        errorText: require_string!(error_text, :error_text) },
                      providerExecuted: provider_executed, providerMetadata: provider_metadata,
                      toolMetadata: tool_metadata, dynamic: dynamic)
        tool[:state] = :output_error
        self
      end

      def tool_output_denied(tool_call_id:)
        ensure_active_step!
        id = require_id!(tool_call_id)
        tool = require_tool_for_denial!(id)
        emit(type: "tool-output-denied", toolCallId: id)
        tool[:state] = :output_denied
        self
      end

      private

      def write_content(content)
        text, files = normalize_chunk_content(content)
        write_text_content(text) unless text.nil? || text.empty?
        files.each { |attributes| file(**attributes) }
      end

      def normalize_chunk_content(content)
        case content
        when String
          [content, []]
        when RubyLLM::Content
          text = content.text
          unless text.nil? || text.is_a?(String)
            raise ProtocolError, "RubyLLM::Content#text must be a String or nil, got #{text.class}"
          end

          files = content.attachments.map { |attachment| attachment_file_attributes(attachment) }
          [text, files]
        when RubyLLM::Content::Raw
          value = content.value
          return [value, []] if value.is_a?(String)

          raise ProtocolError, "RubyLLM::Content::Raw cannot be mapped to text from #{value.class}"
        else
          raise ProtocolError, "RubyLLM chunk content cannot be mapped to text from #{content.class}"
        end
      end

      def attachment_file_attributes(attachment)
        unless attachment.is_a?(RubyLLM::Attachment) && attachment.url?
          raise ProtocolError, "only URL RubyLLM::Content attachments can be mapped to AI SDK file events"
        end

        { url: attachment.source.to_s, media_type: attachment.mime_type }
      end

      def write_text_content(content)
        @auto_text_id ||= next_id("text")
        text_start(id: @auto_text_id) unless @text_parts.key?(@auto_text_id)
        text_delta(id: @auto_text_id, delta: content)
      end

      def write_reasoning(thinking)
        text = thinking.text
        return if text.nil? || text.empty?

        @auto_reasoning_id ||= next_id("reasoning")
        metadata = thinking.signature ? { rubyLLM: { thoughtSignature: thinking.signature } } : nil
        unless @reasoning_parts.key?(@auto_reasoning_id)
          reasoning_start(id: @auto_reasoning_id, provider_metadata: metadata)
        end
        reasoning_delta(id: @auto_reasoning_id, delta: text, provider_metadata: metadata)
      end

      def write_tool_calls(tool_calls)
        tool_calls.each do |stream_key, tool_call|
          if repeated_tool_call?(tool_call)
            continue_tool_call(stream_key, tool_call)
          elsif tool_call.id
            begin_tool_call(stream_key, tool_call)
          else
            append_tool_call(stream_key, tool_call)
          end
        end
      end

      def repeated_tool_call?(tool_call)
        tool_call.id && !tool_call.id.empty? && @tools.key?(tool_call.id)
      end

      def begin_tool_call(stream_key, tool_call)
        id = tool_call.id.empty? ? next_id("tool") : tool_call.id
        validate_tool_key_binding!(stream_key, id)
        validate_tool_key_binding!(tool_call.id, id)
        metadata = tool_call.thought_signature ? { rubyLLM: { thoughtSignature: tool_call.thought_signature } } : nil
        tool_input_start(tool_call_id: id, tool_name: tool_call.name, provider_metadata: metadata)
        bind_tool_key(stream_key, id)
        bind_tool_key(tool_call.id, id)
        @latest_tool_id = id

        append_tool_input(id, tool_call)
      end

      def continue_tool_call(stream_key, tool_call)
        id = tool_call.id
        tool = require_tool!(id)
        require_tool_state!(tool, id, :input_streaming)
        unless tool_call.name == tool[:name]
          raise ProtocolError, "repeated tool invocation #{id.inspect} must keep tool name #{tool[:name].inspect}"
        end

        validate_tool_key_binding!(stream_key, id)
        bind_tool_key(stream_key, id)
        @latest_tool_id = id

        append_tool_input(id, tool_call)
      end

      def validate_tool_key_binding!(key, id)
        return if key.nil?

        existing = @tool_ids_by_stream_key[key]
        return if existing.nil? || existing == id

        raise ProtocolError, "tool stream key #{key.inspect} already identifies invocation #{existing.inspect}"
      end

      def bind_tool_key(key, id)
        @tool_ids_by_stream_key[key] = id unless key.nil?
      end

      def append_tool_input(id, tool_call)
        tool = @tools.fetch(id)
        if tool_call.thought_signature && tool[:options][:providerMetadata].nil?
          tool[:options][:providerMetadata] = provider_metadata(
            rubyLLM: { thoughtSignature: tool_call.thought_signature }
          )
        end

        arguments = tool_call.arguments
        return if arguments.nil? || (arguments.respond_to?(:empty?) && arguments.empty?)

        if arguments.is_a?(Hash) || arguments.is_a?(Array)
          unless tool[:input_text].empty? && tool[:structured_input].nil?
            raise ProtocolError, "cannot append structured input to streamed JSON for tool #{id.inspect}"
          end

          tool[:structured_input] = json_value(arguments)
        else
          tool_input_delta(tool_call_id: id, input_text_delta: arguments.to_s)
        end
      end

      def append_tool_call(stream_key, tool_call)
        id = stream_key.nil? ? @latest_tool_id : @tool_ids_by_stream_key[stream_key]
        raise ProtocolError, "tool input fragment has no matching invocation" unless id

        tool = @tools.fetch(id)
        if tool_call.name && tool_call.name != tool[:name]
          raise ProtocolError, "tool input fragment name does not match invocation #{id.inspect}"
        end

        append_tool_input(id, tool_call)
      end

      def close_open_parts
        @text_parts.each_key { |id| text_end(id: id) }
        @reasoning_parts.each_key { |id| reasoning_end(id: id) }
        @auto_text_id = nil
        @auto_reasoning_id = nil
      end

      def flush_tool_inputs
        @tools.each do |id, tool|
          next unless tool[:state] == :input_streaming && tool[:step] == @step_generation

          options = tool[:options]
          input = tool[:structured_input]
          input = parse_tool_input(tool[:input_text]) if input.nil?
          tool_input_available(tool_call_id: id, tool_name: tool[:name], input: input,
                               provider_executed: options[:providerExecuted],
                               provider_metadata: options[:providerMetadata], tool_metadata: options[:toolMetadata],
                               dynamic: options[:dynamic], title: options[:title])
        rescue JSON::ParserError => e
          tool_input_error(tool_call_id: id, tool_name: tool[:name], input: tool[:input_text],
                           error_text: "invalid JSON tool input: #{e.message}",
                           provider_executed: options[:providerExecuted],
                           provider_metadata: options[:providerMetadata], tool_metadata: options[:toolMetadata],
                           dynamic: options[:dynamic], title: options[:title])
        end
      end

      def parse_tool_input(text) = text.empty? ? {} : JSON.parse(text)

      def clear_current_step_state
        @text_parts.clear
        @reasoning_parts.clear
        current_ids = @tools.filter_map { |id, tool| id if tool[:step] == @step_generation }
        current_ids.each { |id| @tools.delete(id) }
        @approvals.delete_if { |_id, approval| current_ids.include?(approval[:tool_call_id]) }
        @tool_ids_by_stream_key.clear
        @latest_tool_id = nil
        @auto_text_id = nil
        @auto_reasoning_id = nil
      end

      def register_or_require_streaming_tool(id, tool_name, options)
        name = require_string!(tool_name, :tool_name)
        tool = @tools[id]
        if tool
          require_tool_state!(tool, id, :input_streaming)
          raise ProtocolError, "tool name does not match invocation #{id.inspect}" unless tool[:name] == name

          tool
        else
          @tools[id] = { name: name, state: :input_streaming, input_text: +"", structured_input: nil,
                         options: options, step: @step_generation }
        end
      end

      def merged_tool_options(tool, options)
        tool[:options].merge(options) { |_key, old, new| new.nil? ? old : new }
      end

      def tool_options(provider_executed:, provider_metadata:, tool_metadata:, dynamic:, title:)
        {
          providerExecuted: optional_boolean(provider_executed, :provider_executed),
          providerMetadata: provider_metadata.nil? ? nil : provider_metadata(provider_metadata),
          toolMetadata: tool_metadata.nil? ? nil : json_object(tool_metadata, :tool_metadata),
          dynamic: optional_boolean(dynamic, :dynamic),
          title: title.nil? ? nil : require_string!(title, :title)
        }
      end

      def require_tool!(id)
        @tools[id] || raise(ProtocolError, "tool invocation #{id.inspect} has not been declared")
      end

      def require_tool_for_output!(id)
        tool = require_tool!(id)
        terminal = %i[output_available output_error output_denied]
        if terminal.include?(tool[:state])
          raise ProtocolError, "tool invocation #{id.inspect} is already terminal (#{tool[:state]})"
        end
        unless %i[input_available input_error approval_approved output_preliminary].include?(tool[:state])
          raise ProtocolError, "tool invocation #{id.inspect} has no available input"
        end

        tool
      end

      def require_tool_for_denial!(id)
        tool = require_tool!(id)
        unless %i[input_available approval_denied].include?(tool[:state])
          raise ProtocolError, "tool invocation #{id.inspect} cannot be denied from #{tool[:state]}"
        end

        tool
      end

      def require_tool_state!(tool, id, expected)
        return if tool[:state] == expected

        raise ProtocolError, "tool invocation #{id.inspect} is #{tool[:state]}, expected #{expected}"
      end

      def require_part!(parts, id, kind)
        return if parts.key?(id)

        raise ProtocolError, "#{kind} part #{id.inspect} has not started"
      end

      def emit_optional(event, **optional)
        optional.each do |key, value|
          next if value.nil?

          event[key] = if key == :providerMetadata
                         provider_metadata(value)
                       elsif key == :toolMetadata
                         json_object(value, key)
                       elsif %i[providerExecuted dynamic transient preliminary isAutomatic approved].include?(key)
                         require_boolean!(value, key)
                       elsif key == :approvalDescriptor
                         json_value(value)
                       else
                         require_string!(value, key)
                       end
        end
        emit(event)
      end

      def emit(event)
        frame = "data: #{JSON.generate(json_value(event))}\n\n"
        @frames << frame unless @io
        @io&.write(frame)
        frame
      end

      def terminate!
        frame = "data: [DONE]\n\n"
        @frames << frame unless @io
        @io&.write(frame)
        @finished = true
      end

      def ensure_active_step!
        ensure_writable!
        ensure_started!
        start_step unless @step_active
      end

      def ensure_started!
        start unless @started
      end

      def require_active_step!
        raise ProtocolError, "no step is active" unless @step_active
      end

      def ensure_writable!
        raise FinishedError, "the stream has already finished" if @finished
      end

      def normalize_finish_reason(reason)
        normalized = reason.to_s.tr("_", "-")
        FINISH_REASONS.include?(normalized) ? normalized : "other"
      end

      def next_id(prefix) = "#{prefix}-#{@id_generator.call}"

      def require_id!(value)
        value = require_string!(value, :id)
        raise ArgumentError, "id must not be empty" if value.empty?

        value
      end

      def require_string!(value, name)
        return value if value.is_a?(String)

        raise ArgumentError, "#{name} must be a String"
      end

      def optional_boolean(value, name) = value.nil? ? nil : require_boolean!(value, name)

      def require_boolean!(value, name)
        return value if [true, false].include?(value)

        raise ArgumentError, "#{name} must be true or false"
      end

      def json_object(value, name)
        value = json_value(value)
        return value if value.is_a?(Hash)

        raise JSONCompatibilityError, "#{name} must be a JSON object"
      end

      def provider_metadata(value)
        metadata = json_object(value, :provider_metadata)
        raise JSONCompatibilityError, "provider_metadata values must be JSON objects" unless metadata.values.all?(Hash)

        metadata
      end

      def json_value(value, path = "value")
        case value
        when nil, true, false, String, Integer
          value
        when Float
          raise JSONCompatibilityError, "#{path} contains a non-finite number" unless value.finite?

          value
        when Array
          value.each_with_index.map { |item, index| json_value(item, "#{path}[#{index}]") }
        when Hash
          value.each_with_object({}) do |(key, item), result|
            unless key.is_a?(String) || key.is_a?(Symbol)
              raise JSONCompatibilityError, "#{path} contains a non-string key #{key.inspect}"
            end

            result[key.to_s] = json_value(item, "#{path}.#{key}")
          end
        else
          raise JSONCompatibilityError, "#{path} contains unsupported #{value.class}"
        end
      end
    end
    # rubocop:enable Metrics/ClassLength, Metrics/MethodLength, Metrics/AbcSize
    # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/ParameterLists
  end
end
