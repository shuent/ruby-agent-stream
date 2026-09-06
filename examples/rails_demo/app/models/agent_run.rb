class AgentRun < ApplicationRecord
  validates :run_id, presence: true, uniqueness: true
  validates :adapter, :provider_model, :status, presence: true

  def tools
    JSON.parse(tool_names)
  end
end
