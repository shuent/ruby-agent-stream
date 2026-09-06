class RemoveAgentResponseCache < ActiveRecord::Migration[8.1]
  def up
    drop_table :agent_cache_entries
    remove_column :agent_runs, :cache_status
    remove_column :agent_runs, :normalized_prompt
    add_index :agent_conversations, [:session_digest, :updated_at]
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Discarded response caches cannot be restored"
  end
end
