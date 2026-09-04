class ChatsController < ApplicationController
  include ActionController::Live

  skip_forgery_protection
  before_action :allow_local_client

  def create
    stream = nil
    sequence = 0
    stream = RubyLLM::Stream::AISDK.new(
      response.stream,
      message_id: assistant_message_id,
      id_generator: -> { "demo-part-#{sequence += 1}" }
    )
    stream.headers.each { |name, value| response.headers[name] = value }

    DemoConversation.new(stream).run(scenario: params.fetch(:scenario, "complete"))
  rescue ActionController::Live::ClientDisconnected, IOError
    # A cancelled useChat request closes the socket. That is an expected outcome.
    Rails.logger.info("AI SDK client disconnected")
  rescue StandardError => error
    Rails.logger.error(error.full_message)
    terminate_failed_stream(stream)
  ensure
    response.stream.close
  end

  def preflight
    head :no_content
  end

  private

  def assistant_message_id
    user_message_id = params[:messages]&.last&.[](:id)
    ["rails-demo-assistant", user_message_id].compact.join("-")
  end

  def terminate_failed_stream(stream)
    stream&.error(error_text: "Agent stream failed") unless stream&.finished?
  rescue ActionController::Live::ClientDisconnected, IOError
    Rails.logger.info("AI SDK client disconnected while reporting an error")
  end

  def allow_local_client
    origin = request.headers["Origin"]
    return unless origin&.match?(%r{\Ahttps?://(localhost|127\.0\.0\.1)(:\d+)?\z})

    response.headers["Access-Control-Allow-Origin"] = origin
    response.headers["Access-Control-Allow-Headers"] = "Content-Type"
    response.headers["Access-Control-Allow-Methods"] = "POST, OPTIONS"
    response.headers["Vary"] = "Origin"
  end
end
