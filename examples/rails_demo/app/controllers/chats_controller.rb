class ChatsController < ApplicationController
  include ActionController::Live

  skip_forgery_protection
  before_action :allow_local_client

  def create
    stream_events(DemoModel.new.stream(scenario: params.fetch(:scenario, "complete")).map do |provider_event|
      AgentStream::UIMessage::V1::Event.new(provider_event.type, **provider_event.payload)
    end)
  end

  def openai
    stream_agent("openai")
  end

  def ruby_llm
    stream_agent("ruby_llm")
  end

  def preflight
    head :no_content
  end

  private

  def stream_agent(adapter)
    agent = AgentChat.new(
      adapter: adapter, messages: params.fetch(:messages).map(&:to_unsafe_h),
      conversation: AgentConversation.for_session!(params.fetch(:id), request.headers["X-Demo-Session"]),
      regenerate: ActiveModel::Type::Boolean.new.cast(params[:regenerate]),
      debug_error: Rails.env.development? && ActiveModel::Type::Boolean.new.cast(params[:debug_error])
    )
    response.headers["X-Agent-Run-Id"] = agent.run.run_id
    response.headers["X-Agent-Cache"] = agent.run.cache_status
    stream_events(agent, continuation: agent.continuation_events)
  rescue StandardError => error
    Rails.logger.error("Agent request failed: #{error.class}: #{error.message}")
    stream_error(error.message) unless response.committed?
  end

  def stream_events(events, continuation: nil)
    ui_stream = AgentStream::UIMessage::V1::Stream.new(response.stream, continuation: continuation)
    ui_stream.headers.each { |name, value| response.headers[name] = value }
    active_step = false
    events.each do |event|
      ui_stream << event
      active_step = true if event.type == :start_step
      active_step = false if event.type == :finish_step
    end
  rescue ActionController::Live::ClientDisconnected, IOError
    Rails.logger.info("UI message client disconnected")
  rescue StandardError => error
    Rails.logger.error("Agent stream failed: #{error.class}")
    unless ui_stream.finished?
      ui_stream << AgentStream::UIMessage::V1::Event.new(:start, message_id: "agent-error-#{SecureRandom.hex(4)}") unless ui_stream.started?
      if active_step
        ui_stream << AgentStream::UIMessage::V1::Event.new(:reset_step)
        ui_stream << AgentStream::UIMessage::V1::Event.new(:finish_step)
      end
      ui_stream << AgentStream::UIMessage::V1::Event.new(:error, error_text: error.message)
    end
  ensure
    response.stream.close
  end

  def stream_error(message)
    stream_events([
      AgentStream::UIMessage::V1::Event.new(:start, message_id: "agent-error-#{SecureRandom.hex(4)}"),
      AgentStream::UIMessage::V1::Event.new(:start_step),
      AgentStream::UIMessage::V1::Event.new(:finish_step),
      AgentStream::UIMessage::V1::Event.new(:error, error_text: message)
    ])
  end

  def allow_local_client
    origin = request.headers["Origin"]
    return unless origin&.match?(%r{\Ahttps?://(localhost|127\.0\.0\.1)(:\d+)?\z})

    response.headers["Access-Control-Allow-Origin"] = origin
    response.headers["Access-Control-Allow-Headers"] = "Content-Type, X-Demo-Session"
    response.headers["Access-Control-Allow-Methods"] = "POST, OPTIONS"
    response.headers["Access-Control-Expose-Headers"] = "X-Agent-Run-Id, X-Agent-Cache"
    response.headers["Vary"] = "Origin"
  end
end
