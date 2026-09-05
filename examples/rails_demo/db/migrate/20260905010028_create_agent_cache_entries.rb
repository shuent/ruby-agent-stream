class CreateAgentCacheEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_cache_entries do |t|
      t.string :request_digest, null: false
      t.string :adapter, null: false
      t.string :provider_model, null: false
      t.text :normalized_prompt, null: false
      t.text :event_log, null: false
      t.text :run_metadata, null: false

      t.timestamps
    end
    add_index :agent_cache_entries, :request_digest, unique: true
  end
end
