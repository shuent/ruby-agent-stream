class CreateAgentRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_runs do |t|
      t.string :run_id, null: false
      t.string :adapter, null: false
      t.string :provider_model, null: false
      t.string :cache_status, null: false
      t.text :normalized_prompt, null: false
      t.text :tool_names, null: false, default: "[]"
      t.boolean :reasoning_observed, null: false, default: false
      t.string :status, null: false
      t.text :error_message

      t.timestamps
    end
    add_index :agent_runs, :run_id, unique: true
  end
end
