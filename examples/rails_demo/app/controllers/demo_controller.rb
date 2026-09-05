class DemoController < ApplicationController
  skip_forgery_protection
  rescue_from ArgumentError, ActiveRecord::RecordNotFound, with: :invalid_request

  def show
    render json: InventoryCatalog.new.dashboard
  end

  def reset
    raise ArgumentError, "リセットの確認が必要です" unless params[:confirmed] == true
    render json: DemoInventory.reset!
  end

  def create_conversation
    render json: AgentConversation.start!(adapter: params.fetch(:adapter), session_token: request.headers["X-Demo-Session"]).public_result
  end

  def conversation
    render json: AgentConversation.for_session!(params[:id], request.headers["X-Demo-Session"]).public_result
  end

  private

  def invalid_request(error)
    render json: { error: error.is_a?(ActiveRecord::RecordNotFound) ? "会話またはデータが見つかりません" : error.message }, status: :unprocessable_entity
  end
end
