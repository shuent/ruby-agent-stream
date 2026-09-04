class ChatsController < ApplicationController
  include ActionController::Live

  skip_forgery_protection
  before_action :allow_local_client

  def create
    ui_stream = AIStream::UIMessage::V1::Stream.new(response.stream)
    ui_stream.headers.each { |name, value| response.headers[name] = value }

    DemoModel.new.stream(scenario: params.fetch(:scenario, "complete")).each do |provider_event|
      ui_stream << AIStream::UIMessage::V1::Event.new(provider_event.type, **provider_event.payload)
    end
  rescue ActionController::Live::ClientDisconnected, IOError
    Rails.logger.info("UI message client disconnected")
  rescue StandardError => error
    Rails.logger.error(error.full_message)
  ensure
    response.stream.close
  end

  def preflight
    head :no_content
  end

  private

  def allow_local_client
    origin = request.headers["Origin"]
    return unless origin&.match?(%r{\Ahttps?://(localhost|127\.0\.0\.1)(:\d+)?\z})

    response.headers["Access-Control-Allow-Origin"] = origin
    response.headers["Access-Control-Allow-Headers"] = "Content-Type"
    response.headers["Access-Control-Allow-Methods"] = "POST, OPTIONS"
    response.headers["Vary"] = "Origin"
  end
end
