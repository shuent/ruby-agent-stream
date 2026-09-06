class ConversationsController < ApplicationController
  skip_forgery_protection
  rescue_from ArgumentError, ActiveRecord::RecordNotFound, with: :invalid_request

  def index
    render json: AgentConversation.for_session(request.headers["X-Demo-Session"]).map(&:summary)
  end

  def create
    render json: AgentConversation.start!(adapter: params.fetch(:adapter), session_token: request.headers["X-Demo-Session"]).public_result
  end

  def show
    render json: AgentConversation.for_session!(params[:id], request.headers["X-Demo-Session"]).public_result
  end

  private

  def invalid_request(error)
    render json: { error: error.is_a?(ActiveRecord::RecordNotFound) ? "会話が見つかりません" : error.message }, status: :unprocessable_entity
  end
end
