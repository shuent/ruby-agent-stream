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

  private

  def invalid_request(error)
    render json: { error: error.is_a?(ActiveRecord::RecordNotFound) ? "会話またはデータが見つかりません" : error.message }, status: :unprocessable_entity
  end
end
