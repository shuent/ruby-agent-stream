# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_05_061902) do
  create_table "agent_approvals", force: :cascade do |t|
    t.integer "agent_conversation_id", null: false
    t.datetime "created_at", null: false
    t.string "data_revision", null: false
    t.json "input", null: false
    t.string "message_id", null: false
    t.json "outcome"
    t.string "public_id", null: false
    t.string "status", default: "pending", null: false
    t.string "tool_call_id", null: false
    t.string "tool_name", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_conversation_id", "tool_call_id"], name: "idx_on_agent_conversation_id_tool_call_id_8ef28a5748", unique: true
    t.index ["agent_conversation_id"], name: "index_agent_approvals_on_agent_conversation_id"
    t.index ["public_id"], name: "index_agent_approvals_on_public_id", unique: true
  end

  create_table "agent_cache_entries", force: :cascade do |t|
    t.string "adapter", null: false
    t.datetime "created_at", null: false
    t.text "event_log", null: false
    t.text "normalized_prompt", null: false
    t.string "provider_model", null: false
    t.string "request_digest", null: false
    t.text "run_metadata", null: false
    t.datetime "updated_at", null: false
    t.index ["request_digest"], name: "index_agent_cache_entries_on_request_digest", unique: true
  end

  create_table "agent_conversations", force: :cascade do |t|
    t.string "active_run"
    t.string "adapter", null: false
    t.datetime "created_at", null: false
    t.json "last_events", default: [], null: false
    t.json "messages", default: [], null: false
    t.string "public_id", null: false
    t.string "session_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["public_id"], name: "index_agent_conversations_on_public_id", unique: true
  end

  create_table "agent_runs", force: :cascade do |t|
    t.string "adapter", null: false
    t.string "cache_status", null: false
    t.datetime "created_at", null: false
    t.text "error_message"
    t.text "normalized_prompt", null: false
    t.string "provider_model", null: false
    t.boolean "reasoning_observed", default: false, null: false
    t.string "run_id", null: false
    t.string "status", null: false
    t.text "tool_names", default: "[]", null: false
    t.datetime "updated_at", null: false
    t.index ["run_id"], name: "index_agent_runs_on_run_id", unique: true
  end

  create_table "demo_revisions", force: :cascade do |t|
    t.string "token", null: false
  end

  create_table "inventory_items", force: :cascade do |t|
    t.string "category", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "reorder_point", default: 0, null: false
    t.string "sku", null: false
    t.integer "stock_on_hand", default: 0, null: false
    t.integer "stock_reserved", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["sku"], name: "index_inventory_items_on_sku", unique: true
  end

  create_table "replenishment_orders", force: :cascade do |t|
    t.integer "agent_approval_id", null: false
    t.datetime "created_at", null: false
    t.integer "estimated_cost_yen", null: false
    t.integer "quantity", null: false
    t.string "sku", null: false
    t.string "status", default: "registered", null: false
    t.string "supplier_name", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_approval_id"], name: "index_replenishment_orders_on_agent_approval_id", unique: true
  end

  create_table "sales_metrics", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "inventory_item_id", null: false
    t.integer "period_days", null: false
    t.integer "units_sold", null: false
    t.datetime "updated_at", null: false
    t.index ["inventory_item_id", "period_days"], name: "index_sales_metrics_on_inventory_item_id_and_period_days", unique: true
    t.index ["inventory_item_id"], name: "index_sales_metrics_on_inventory_item_id"
  end

  create_table "supplier_terms", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "inventory_item_id", null: false
    t.integer "lead_time_days", null: false
    t.integer "min_order_quantity", null: false
    t.integer "pack_size", null: false
    t.string "supplier_name", null: false
    t.decimal "unit_cost", precision: 10, scale: 2, null: false
    t.datetime "updated_at", null: false
    t.index ["inventory_item_id"], name: "index_supplier_terms_on_inventory_item_id", unique: true
  end

  add_foreign_key "agent_approvals", "agent_conversations"
  add_foreign_key "replenishment_orders", "agent_approvals"
  add_foreign_key "sales_metrics", "inventory_items"
  add_foreign_key "supplier_terms", "inventory_items"
end
