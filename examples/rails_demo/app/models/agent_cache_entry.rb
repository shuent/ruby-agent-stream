class AgentCacheEntry < ApplicationRecord
  validates :request_digest, presence: true, uniqueness: true
  validates :adapter, :provider_model, :normalized_prompt, :event_log, :run_metadata, presence: true

  def events
    JSON.parse(event_log, symbolize_names: true)
  end

  def metadata
    JSON.parse(run_metadata, symbolize_names: true)
  end
end
