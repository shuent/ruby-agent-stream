# frozen_string_literal: true

require "json"

module AgentStream
  module UIMessage
    module V1
      # Validates event order and writes AI SDK UI Message Stream Protocol v1 SSE frames.
      # A protocol state machine necessarily dispatches across every event.
      # Keeping those transitions visible in one class makes ordering auditable.
      # rubocop:disable Metrics/ClassLength, Metrics/MethodLength, Metrics/AbcSize
      # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      class Stream
        include Enumerable

        HEADERS = {
          "content-type" => "text/event-stream",
          "cache-control" => "no-cache",
          "connection" => "keep-alive",
          "x-vercel-ai-ui-message-stream" => "v1",
          "x-accel-buffering" => "no"
        }.freeze
        TERMINAL_TYPES = %i[finish abort error].freeze

        class Error < StandardError; end
        class ProtocolError < Error; end
        class FinishedError < Error; end

        attr_reader :frames

        def self.headers = HEADERS.dup

        def initialize(sink = nil, continuation: nil)
          @sink = sink
          @frames = []
          @started = false
          @step_active = false
          @finished = false
          @step = 0
          @parts = {}
          @tools = {}
          @approvals = {}
          restore_continuation!(continuation) if continuation
        end

        def headers = self.class.headers
        def started? = @started
        def finished? = @finished
        def to_a = frames.dup

        def each(&block)
          return enum_for(:each) unless block

          frames.each(&block)
          self
        end

        def <<(event)
          ensure_writable!
          raise ArgumentError, "expected #{Event}, got #{event.class}" unless event.is_a?(Event)

          transition!(event)
          emit(event)
          terminate! if TERMINAL_TYPES.include?(event.type)
          self
        end

        private

        # Rebuild protocol state from trusted, server-owned event history without
        # replaying frames or executing tools. Each HTTP segment must finish.
        def restore_continuation!(history)
          last_type = nil
          history.each do |event|
            raise ArgumentError, "expected #{Event}, got #{event.class}" unless event.is_a?(Event)
            raise ProtocolError, "cannot continue an aborted or failed stream" if %i[abort error].include?(event.type)

            @started = false if last_type == :finish
            transition!(event)
            last_type = event.type
          end
          raise ProtocolError, "continuation history must end with finish" unless last_type == :finish

          @started = false
        end

        def transition!(event)
          case event.type
          when :start then start_message!
          when :start_step then start_step!
          when :reset_step then reset_step!
          when :finish_step then finish_step!
          when :finish, :abort, :error then finish_message!
          when :text_start then start_part!(event, :text)
          when :text_delta then continue_part!(event, :text)
          when :text_end then end_part!(event, :text)
          when :reasoning_start then start_part!(event, :reasoning)
          when :reasoning_delta then continue_part!(event, :reasoning)
          when :reasoning_end then end_part!(event, :reasoning)
          when :tool_input_start then start_tool!(event)
          when :tool_input_delta then stream_tool_input!(event)
          when :tool_input_available, :tool_input_error then finish_tool_input!(event)
          when :tool_approval_request then request_tool_approval!(event)
          when :tool_approval_response then answer_tool_approval!(event)
          when :tool_output_available, :tool_output_error then finish_tool_output!(event)
          when :tool_output_denied then deny_tool_output!(event)
          else require_active_step!
          end
        end

        def start_message!
          raise ProtocolError, "the stream has already started" if @started

          @started = true
        end

        def start_step!
          ensure_started!
          raise ProtocolError, "a step is already active" if @step_active

          @step_active = true
          @step += 1
        end

        def reset_step!
          require_active_step!
          current_tool_ids = @tools.filter_map { |id, tool| id if tool[:step] == @step }
          @parts.delete_if { |_id, part| part[:step] == @step }
          current_tool_ids.each { |id| @tools.delete(id) }
          @approvals.delete_if { |_id, approval| current_tool_ids.include?(approval[:tool_call_id]) }
        end

        def finish_step!
          require_active_step!
          open_parts = @parts.filter_map { |id, part| id if part[:step] == @step }
          raise ProtocolError, "step has open parts: #{open_parts.map(&:inspect).join(", ")}" unless open_parts.empty?

          streaming_tools = @tools.filter_map do |id, tool|
            id if tool[:step] == @step && tool[:state] == :input_streaming
          end
          unless streaming_tools.empty?
            raise ProtocolError, "step has incomplete tool inputs: #{streaming_tools.map(&:inspect).join(", ")}"
          end

          @step_active = false
        end

        def finish_message!
          ensure_started!
          raise ProtocolError, "cannot finish while a step is active" if @step_active
        end

        def start_part!(event, kind)
          require_active_step!
          id = event[:id]
          raise ProtocolError, "part #{id.inspect} has already started" if @parts.key?(id)

          @parts[id] = { kind: kind, step: @step }
        end

        def continue_part!(event, kind)
          require_active_step!
          require_part!(event[:id], kind)
        end

        def end_part!(event, kind)
          require_active_step!
          id = event[:id]
          require_part!(id, kind)
          @parts.delete(id)
        end

        def require_part!(id, kind)
          part = @parts[id]
          raise ProtocolError, "#{kind} part #{id.inspect} has not started" unless part
          raise ProtocolError, "part #{id.inspect} is #{part[:kind]}, not #{kind}" unless part[:kind] == kind
          raise ProtocolError, "part #{id.inspect} belongs to another step" unless part[:step] == @step
        end

        def start_tool!(event)
          require_active_step!
          id = event[:tool_call_id]
          raise ProtocolError, "tool invocation #{id.inspect} already exists" if @tools.key?(id)

          @tools[id] = { name: event[:tool_name], state: :input_streaming, step: @step }
        end

        def stream_tool_input!(event)
          tool = require_tool!(event[:tool_call_id])
          require_tool_state!(tool, event[:tool_call_id], :input_streaming)
        end

        def finish_tool_input!(event)
          id = event[:tool_call_id]
          tool = @tools[id]
          if tool
            require_tool_state!(tool, id, :input_streaming)
            unless tool[:name] == event[:tool_name]
              raise ProtocolError, "tool name does not match invocation #{id.inspect}"
            end
          else
            require_active_step!
            @tools[id] = tool = { name: event[:tool_name], state: :input_streaming, step: @step }
          end
          tool[:state] = event.type == :tool_input_available ? :input_available : :input_error
          nil
        end

        def request_tool_approval!(event)
          id = event[:tool_call_id]
          tool = require_tool!(id)
          unless %i[input_available output_preliminary].include?(tool[:state])
            raise ProtocolError, "tool invocation #{id.inspect} is not ready for approval"
          end

          approval_id = event[:approval_id]
          raise ProtocolError, "approval #{approval_id.inspect} already exists" if @approvals.key?(approval_id)

          @approvals[approval_id] = { tool_call_id: id, responded: false }
          tool[:state] = :approval_requested
        end

        def answer_tool_approval!(event)
          require_active_step!
          approval_id = event[:approval_id]
          approval = @approvals[approval_id]
          raise ProtocolError, "approval #{approval_id.inspect} has not been requested" unless approval
          raise ProtocolError, "approval #{approval_id.inspect} has already been answered" if approval[:responded]

          approval[:responded] = true
          @tools.fetch(approval[:tool_call_id])[:state] = event[:approved] ? :approval_approved : :approval_denied
        end

        def finish_tool_output!(event)
          id = event[:tool_call_id]
          tool = require_tool!(id)
          terminal = %i[output_available output_error output_denied]
          raise ProtocolError, "tool invocation #{id.inspect} is already terminal" if terminal.include?(tool[:state])
          unless %i[input_available input_error approval_approved output_preliminary].include?(tool[:state])
            raise ProtocolError, "tool invocation #{id.inspect} has no available input"
          end

          preliminary = event.type == :tool_output_available && event.attributes.fetch(:preliminary, false)
          tool[:state] = preliminary ? :output_preliminary : event.type
        end

        def deny_tool_output!(event)
          id = event[:tool_call_id]
          tool = require_tool!(id)
          unless %i[input_available approval_denied].include?(tool[:state])
            raise ProtocolError, "tool invocation #{id.inspect} cannot be denied from #{tool[:state]}"
          end

          tool[:state] = :output_denied
        end

        def require_tool!(id)
          require_active_step!
          @tools[id] || raise(ProtocolError, "tool invocation #{id.inspect} has not been declared")
        end

        def require_tool_state!(tool, id, expected)
          return if tool[:state] == expected

          raise ProtocolError, "tool invocation #{id.inspect} is #{tool[:state]}, expected #{expected}"
        end

        def require_active_step!
          ensure_started!
          raise ProtocolError, "no step is active" unless @step_active
        end

        def ensure_started!
          raise ProtocolError, "the stream has not started" unless @started
        end

        def ensure_writable!
          raise FinishedError, "the stream has already finished" if @finished
        end

        def emit(event)
          frame = "data: #{JSON.generate(event.to_h)}\n\n"
          @sink ? @sink.write(frame) : @frames << frame
        end

        def terminate!
          frame = "data: [DONE]\n\n"
          @sink ? @sink.write(frame) : @frames << frame
          @finished = true
        end
      end
      # rubocop:enable Metrics/ClassLength, Metrics/MethodLength, Metrics/AbcSize
      # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    end
  end
end
