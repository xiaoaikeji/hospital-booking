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

ActiveRecord::Schema[8.1].define(version: 2026_11_17_080000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.timestamp "created_at", precision: 6, null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.timestamp "created_at", precision: 6, null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "admins", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "current_sign_in_at"
    t.inet "current_sign_in_ip"
    t.boolean "enabled", default: true, null: false
    t.string "encrypted_password", default: "", null: false
    t.datetime "last_sign_in_at"
    t.inet "last_sign_in_ip"
    t.string "name", limit: 100
    t.datetime "remember_created_at"
    t.string "role", limit: 30, default: "operator", null: false
    t.integer "sign_in_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.string "username", limit: 100, null: false
    t.index ["username"], name: "index_admins_on_username", unique: true
    t.check_constraint "role::text = ANY (ARRAY['super_admin'::character varying, 'operator'::character varying, 'customer_service'::character varying]::text[])", name: "admins_role_allowed"
  end

  create_table "logs", force: :cascade do |t|
    t.string "action", limit: 100, null: false
    t.bigint "actor_id"
    t.string "actor_type", limit: 50
    t.string "category", limit: 50, null: false
    t.string "correlation_id", limit: 100
    t.datetime "created_at", null: false
    t.jsonb "details", default: {}, null: false
    t.integer "duration_ms"
    t.string "error_class", limit: 150
    t.text "error_message"
    t.inet "ip_address"
    t.string "job_id", limit: 100
    t.string "level", limit: 20, default: "info", null: false
    t.string "request_id", limit: 100
    t.string "source", limit: 30, null: false
    t.string "status", limit: 20, null: false
    t.string "summary", limit: 500
    t.bigint "target_id"
    t.string "target_type", limit: 100
    t.text "user_agent"
    t.index ["action"], name: "index_logs_on_action"
    t.index ["category"], name: "index_logs_on_category"
    t.index ["correlation_id"], name: "index_logs_on_correlation_id"
    t.index ["created_at"], name: "index_logs_on_created_at"
    t.index ["job_id"], name: "index_logs_on_job_id"
    t.index ["request_id"], name: "index_logs_on_request_id"
    t.index ["source"], name: "index_logs_on_source"
  end

  create_table "settings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "description", limit: 255
    t.string "key", limit: 100, null: false
    t.jsonb "settings", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_settings_on_key", unique: true
    t.check_constraint "jsonb_typeof(settings) = 'object'::text", name: "settings_object_required"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
end
