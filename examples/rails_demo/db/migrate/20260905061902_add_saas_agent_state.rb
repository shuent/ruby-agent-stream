class AddSaasAgentState < ActiveRecord::Migration[8.1]
  def change
    create_table :demo_revisions do |t|
      t.string :token, null: false
    end
    create_table :agent_conversations do |t|
      t.string :public_id, null: false
      t.string :session_digest, null: false
      t.string :adapter, null: false
      t.json :messages, null: false, default: []
      t.json :last_events, null: false, default: []
      t.string :active_run
      t.timestamps
    end
    add_index :agent_conversations, :public_id, unique: true
    create_table :agent_approvals do |t|
      t.references :agent_conversation, null: false, foreign_key: true
      t.string :public_id, null: false
      t.string :message_id, null: false
      t.string :tool_call_id, null: false
      t.string :tool_name, null: false
      t.json :input, null: false
      t.string :data_revision, null: false
      t.string :status, null: false, default: "pending"
      t.json :outcome
      t.timestamps
    end
    add_index :agent_approvals, :public_id, unique: true
    add_index :agent_approvals, [:agent_conversation_id, :tool_call_id], unique: true
    create_table :replenishment_orders do |t|
      t.references :agent_approval, null: false, foreign_key: true, index: { unique: true }
      t.string :sku, null: false
      t.integer :quantity, null: false
      t.string :supplier_name, null: false
      t.integer :estimated_cost_yen, null: false
      t.string :status, null: false, default: "registered"
      t.timestamps
    end
  end
end
