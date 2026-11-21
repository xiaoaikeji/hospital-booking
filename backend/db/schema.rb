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

ActiveRecord::Schema[8.1].define(version: 2026_11_21_160000) do
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
    t.jsonb "appearance_overrides", default: {}, null: false
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
    t.check_constraint "jsonb_typeof(appearance_overrides) = 'object'::text", name: "admin_appearance_object_required"
    t.check_constraint "role::text = ANY (ARRAY['super_admin'::character varying, 'operator'::character varying, 'customer_service'::character varying]::text[])", name: "admins_role_allowed"
  end

  create_table "app_authorizations", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.datetime "authorized_at"
    t.datetime "created_at", null: false
    t.datetime "event_at"
    t.bigint "initiator_id"
    t.string "original_id"
    t.text "refresh_token"
    t.datetime "revoked_at"
    t.jsonb "scopes", default: [], null: false
    t.string "state_digest"
    t.datetime "state_expires_at"
    t.datetime "updated_at", null: false
    t.index ["app_id"], name: "index_app_authorizations_on_app_id", unique: true
    t.index ["initiator_id"], name: "index_app_authorizations_on_initiator_id"
  end

  create_table "apps", force: :cascade do |t|
    t.string "app_type", default: "mini_program", null: false
    t.string "appid", null: false
    t.text "appsecret"
    t.text "callback_encoding_aes_key"
    t.text "callback_token"
    t.datetime "created_at", null: false
    t.integer "lock_version", default: 0, null: false
    t.text "memo"
    t.string "nickname"
    t.bigint "open_platform_account_id"
    t.string "provider", null: false
    t.string "status", default: "disabled", null: false
    t.datetime "updated_at", null: false
    t.string "verified_digest"
    t.string "wechat_original_id"
    t.datetime "violations_synced_at"
    t.index ["open_platform_account_id"], name: "index_apps_on_open_platform_account_id"
    t.index ["provider", "appid"], name: "index_apps_on_provider_and_appid", unique: true
    t.index ["wechat_original_id"], name: "index_apps_on_wechat_original_id", unique: true, where: "(wechat_original_id IS NOT NULL)"
    t.check_constraint "app_type::text = 'mini_program'::text OR app_type::text = 'official_account'::text AND provider::text = 'wechat'::text", name: "apps_supported_type"
    t.check_constraint "provider::text = ANY (ARRAY['wechat'::character varying, 'douyin'::character varying]::text[])", name: "apps_provider_valid"
    t.check_constraint "status::text = ANY (ARRAY['active'::character varying, 'auditing'::character varying, 'disabled'::character varying]::text[])", name: "apps_status_valid"
  end

  create_table "links", force: :cascade do |t|
    t.bigint "app_id"
    t.datetime "created_at", null: false
    t.string "link_type", default: "none", null: false
    t.string "name", null: false
    t.jsonb "params", default: {}, null: false
    t.string "position", null: false
    t.integer "sort_order", default: 0, null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.text "url"
    t.index ["app_id", "position", "status", "sort_order", "id"], name: "index_links_on_app_position_status_and_order"
    t.check_constraint "jsonb_typeof(params) = 'object'::text", name: "links_params_object"
    t.check_constraint "link_type::text = ANY (ARRAY['none'::character varying, 'page'::character varying, 'tab'::character varying, 'webview'::character varying, 'miniprogram'::character varying, 'contact'::character varying]::text[])", name: "links_type_valid"
    t.check_constraint "status::text = ANY (ARRAY['active'::character varying, 'disabled'::character varying]::text[])", name: "links_status_valid"
  end

  create_table "location_interface_applications", force: :cascade do |t|
    t.string "api_name", limit: 100, null: false
    t.bigint "app_id", null: false
    t.string "audit_id"
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.integer "error_code"
    t.bigint "operator_id", null: false
    t.jsonb "previous_review", null: false
    t.string "state", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id", "api_name", "id"], name: "idx_on_app_id_api_name_id_f9de7c6d4d"
    t.index ["app_id"], name: "index_location_interface_applications_on_app_id"
    t.index ["operator_id"], name: "index_location_interface_applications_on_operator_id"
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

  create_table "mini_program_audits", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.datetime "approved_at"
    t.string "audit_id"
    t.boolean "auto_publish", default: false, null: false
    t.datetime "created_at", null: false
    t.text "delay_reason"
    t.text "description", null: false
    t.integer "error_code"
    t.bigint "mini_program_release_id"
    t.bigint "operator_id", null: false
    t.string "previous_audit_id"
    t.boolean "previous_audit_pending"
    t.string "previous_status", null: false
    t.string "prior_online_marker"
    t.string "publication", default: "unpublished", null: false
    t.jsonb "publication_attempt"
    t.datetime "published_at"
    t.text "rejection_reason"
    t.text "rejection_screenshots", default: [], null: false, array: true
    t.string "status", default: "submit_unknown", null: false
    t.datetime "submission_finished_at"
    t.datetime "updated_at", null: false
    t.string "version", null: false
    t.index ["app_id", "audit_id"], name: "index_mini_program_audits_on_app_id_and_audit_id", unique: true
    t.index ["app_id"], name: "index_mini_program_audits_on_app_id"
    t.index ["mini_program_release_id"], name: "index_mini_program_audits_on_mini_program_release_id"
    t.index ["operator_id"], name: "index_mini_program_audits_on_operator_id"
  end

  create_table "mini_program_releases", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.text "audit_description"
    t.bigint "confirmed_experience_time"
    t.datetime "created_at", null: false
    t.boolean "current_build", default: false, null: false
    t.text "description", null: false
    t.integer "error_code"
    t.jsonb "ext_config"
    t.bigint "operator_id", null: false
    t.bigint "previous_build_id"
    t.jsonb "prior_experience"
    t.bigint "restored_for_id"
    t.bigint "source_release_id"
    t.string "status", default: "upload_unknown", null: false
    t.string "template_id", null: false
    t.string "template_type", default: "normal", null: false
    t.datetime "updated_at", null: false
    t.string "version", null: false
    t.index ["app_id", "restored_for_id"], name: "index_mini_program_releases_on_app_id_and_restored_for_id", where: "(restored_for_id IS NOT NULL)"
    t.index ["app_id"], name: "index_mini_program_releases_on_app_id"
    t.index ["app_id"], name: "one_current_build_per_app", unique: true, where: "current_build"
    t.index ["operator_id"], name: "index_mini_program_releases_on_operator_id"
    t.index ["previous_build_id"], name: "index_mini_program_releases_on_previous_build_id"
    t.index ["source_release_id"], name: "index_mini_program_releases_on_source_release_id"
  end

  create_table "notifications", force: :cascade do |t|
    t.integer "attempt_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.text "error_message"
    t.string "event", limit: 100, null: false
    t.string "idempotency_key", limit: 150
    t.string "job_id", limit: 100
    t.datetime "last_attempt_at", precision: nil
    t.jsonb "payload", default: {}, null: false
    t.jsonb "response_data", default: {}, null: false
    t.datetime "scheduled_at", precision: nil
    t.datetime "sent_at", precision: nil
    t.string "status", limit: 20, null: false
    t.bigint "subject_id", null: false
    t.string "subject_type", limit: 50, null: false
    t.datetime "updated_at", null: false
    t.index ["event"], name: "index_notifications_on_event"
    t.index ["idempotency_key"], name: "index_notifications_on_idempotency_key", unique: true
    t.index ["status", "scheduled_at"], name: "index_notifications_on_status_and_scheduled_at"
    t.index ["subject_type", "subject_id"], name: "index_notifications_on_subject_type_and_subject_id"
    t.check_constraint "attempt_count >= 0", name: "notifications_attempts_valid"
    t.check_constraint "jsonb_typeof(payload) = 'object'::text AND jsonb_typeof(response_data) = 'object'::text", name: "notifications_objects_required"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'sending'::character varying::text, 'sent'::character varying::text, 'failed'::character varying::text])", name: "notifications_status_valid"
  end

  create_table "official_account_callbacks", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.datetime "created_at", null: false
    t.string "digest", null: false
    t.text "message", null: false
    t.datetime "processed_at", precision: nil
    t.text "reply_xml"
    t.string "sender_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id", "digest"], name: "index_official_account_callbacks_on_app_id_and_digest", unique: true
    t.index ["app_id", "sender_digest"], name: "index_official_account_callbacks_on_app_id_and_sender_digest"
    t.index ["app_id"], name: "index_official_account_callbacks_on_app_id"
  end

  create_table "official_account_fan_events", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.string "digest", null: false
    t.string "event", null: false
    t.datetime "occurred_at", null: false
    t.text "openid", null: false
    t.string "qr_scene"
    t.index ["app_id", "digest"], name: "index_official_account_fan_events_on_app_id_and_digest", unique: true
    t.index ["app_id"], name: "index_official_account_fan_events_on_app_id"
  end

  create_table "official_account_fan_syncs", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.datetime "created_at", null: false
    t.string "error"
    t.integer "fan_count"
    t.bigint "operator_id", null: false
    t.string "state", default: "queued", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id"], name: "index_official_account_fan_syncs_on_app_id"
    t.index ["app_id"], name: "one_active_fan_sync", unique: true, where: "((state)::text = ANY ((ARRAY['queued'::character varying, 'running'::character varying])::text[]))"
    t.index ["operator_id"], name: "index_official_account_fan_syncs_on_operator_id"
  end

  create_table "official_account_fans", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "event_at"
    t.datetime "observed_at", null: false
    t.string "qr_scene"
    t.string "scene"
    t.boolean "subscribed", null: false
    t.datetime "subscribed_at"
    t.datetime "unsubscribed_at"
    t.datetime "updated_at", null: false
    t.bigint "user_app_id", null: false
    t.index ["user_app_id"], name: "index_official_account_fans_on_user_app_id", unique: true
  end

  create_table "official_account_menus", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.jsonb "buttons", default: [], null: false
    t.datetime "created_at", null: false
    t.jsonb "observed_buttons"
    t.jsonb "pending_buttons"
    t.integer "revision", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["app_id"], name: "index_official_account_menus_on_app_id", unique: true
  end

  create_table "official_account_qrcodes", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.datetime "created_at", null: false
    t.string "name", limit: 60, null: false
    t.string "scene", limit: 64, null: false
    t.text "ticket", null: false
    t.datetime "updated_at", null: false
    t.text "url", null: false
    t.index ["app_id", "scene"], name: "index_official_account_qrcodes_on_app_id_and_scene", unique: true
    t.index ["app_id"], name: "index_official_account_qrcodes_on_app_id"
  end

  create_table "open_platform_accounts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "created_via_app_id", null: false
    t.string "name", limit: 120, null: false
    t.string "open_appid", limit: 60, null: false
    t.bigint "operator_id", null: false
    t.datetime "updated_at", null: false
    t.index ["created_via_app_id"], name: "index_open_platform_accounts_on_created_via_app_id"
    t.index ["open_appid"], name: "index_open_platform_accounts_on_open_appid", unique: true
    t.index ["operator_id"], name: "index_open_platform_accounts_on_operator_id"
  end

  create_table "open_platform_operations", force: :cascade do |t|
    t.string "action", null: false
    t.bigint "app_id", null: false
    t.datetime "created_at", null: false
    t.string "name", limit: 120
    t.bigint "open_platform_account_id"
    t.datetime "updated_at", null: false
    t.index ["app_id"], name: "index_open_platform_operations_on_app_id", unique: true
    t.index ["open_platform_account_id"], name: "index_open_platform_operations_on_open_platform_account_id"
    t.check_constraint "action::text = 'create'::text AND open_platform_account_id IS NULL OR (action::text = ANY (ARRAY['bind'::character varying, 'unbind'::character varying]::text[])) AND open_platform_account_id IS NOT NULL", name: "valid_open_platform_operation"
  end

  create_table "posters", force: :cascade do |t|
    t.bigint "app_id"
    t.datetime "created_at", null: false
    t.integer "image_height", null: false
    t.integer "image_width", null: false
    t.string "name", null: false
    t.bigint "official_account_qrcode_id"
    t.string "page_path"
    t.string "page_query"
    t.integer "qr_size", null: false
    t.integer "qr_x", null: false
    t.integer "qr_y", null: false
    t.string "target_kind"
    t.datetime "updated_at", null: false
    t.index ["app_id"], name: "index_posters_on_app_id"
    t.index ["official_account_qrcode_id"], name: "index_posters_on_official_account_qrcode_id"
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

  create_table "user_apps", force: :cascade do |t|
    t.string "appid", limit: 100, null: false
    t.datetime "created_at", null: false
    t.jsonb "first_entry", default: {}, null: false
    t.datetime "last_sign_in_at"
    t.string "openid", limit: 150, null: false
    t.string "provider", null: false
    t.jsonb "sessions", default: {}, null: false
    t.integer "sign_in_count", default: 0, null: false
    t.string "status", default: "active", null: false
    t.string "unionid", limit: 150
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["provider", "appid", "openid"], name: "index_user_apps_on_provider_and_appid_and_openid", unique: true
    t.index ["provider", "unionid"], name: "index_user_apps_on_provider_and_unionid"
    t.index ["user_id", "provider", "appid"], name: "index_user_apps_on_user_id_and_provider_and_appid", unique: true
    t.index ["user_id"], name: "index_user_apps_on_user_id"
    t.check_constraint "(status::text = ANY (ARRAY['active'::character varying, 'disabled'::character varying]::text[])) AND sign_in_count >= 0", name: "valid_user_app"
    t.check_constraint "jsonb_typeof(first_entry) = 'object'::text", name: "user_app_first_entry_object"
    t.check_constraint "jsonb_typeof(sessions) = 'object'::text", name: "user_app_sessions_object"
  end

  create_table "users", force: :cascade do |t|
    t.string "avatar_url", limit: 500
    t.datetime "created_at", null: false
    t.datetime "last_login_at"
    t.jsonb "login_profile", default: {}, null: false
    t.string "mobile", limit: 30
    t.datetime "mobile_verified_at"
    t.string "nickname", limit: 100
    t.string "platform", null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.string "user_no", limit: 8, null: false
    t.index ["id"], name: "users_pending_ip_location", where: "((login_profile ? 'first_ip'::text) AND (NOT (login_profile ? 'region'::text)))"
    t.index ["user_no"], name: "index_users_on_user_no", unique: true
    t.check_constraint "(platform::text = ANY (ARRAY['wechat'::character varying, 'douyin'::character varying]::text[])) AND (status::text = ANY (ARRAY['active'::character varying, 'disabled'::character varying]::text[])) AND user_no::text ~ '^[1-9][0-9]{7}$'::text", name: "valid_terminal_user"
    t.check_constraint "jsonb_typeof(login_profile) = 'object'::text", name: "user_login_profile_object"
  end

  create_table "wechat_appeals", force: :cascade do |t|
    t.datetime "appealed_at"
    t.datetime "audited_at"
    t.datetime "created_at", null: false
    t.string "number", null: false
    t.text "punishment"
    t.text "reason"
    t.integer "status", null: false
    t.datetime "updated_at", null: false
    t.bigint "wechat_violation_id", null: false
    t.index ["wechat_violation_id", "number"], name: "index_wechat_appeals_on_wechat_violation_id_and_number", unique: true
    t.index ["wechat_violation_id"], name: "index_wechat_appeals_on_wechat_violation_id"
  end

  create_table "wechat_category_acceptances", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.datetime "created_at", null: false
    t.integer "first_category", null: false
    t.integer "second_category", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id", "first_category", "second_category"], name: "idx_on_app_id_first_category_second_category_0d40974d54", unique: true
    t.index ["app_id"], name: "index_wechat_category_acceptances_on_app_id"
  end

  create_table "wechat_link_operations", force: :cascade do |t|
    t.string "action", null: false
    t.bigint "app_id", null: false
    t.datetime "created_at", null: false
    t.integer "lock_version", default: 0, null: false
    t.string "mini_appid", null: false
    t.bigint "mini_program_id"
    t.integer "previous_status"
    t.string "state", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id", "mini_appid"], name: "index_wechat_link_operations_on_app_id_and_mini_appid", unique: true
    t.index ["app_id"], name: "index_wechat_link_operations_on_app_id"
    t.index ["mini_program_id"], name: "index_wechat_link_operations_on_mini_program_id"
  end

  create_table "wechat_notification_events", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.datetime "created_at", null: false
    t.integer "error_code"
    t.string "event_key", null: false
    t.string "kind", null: false
    t.text "message", null: false
    t.string "status", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id", "event_key"], name: "index_wechat_notification_events_on_app_id_and_event_key", unique: true
    t.index ["app_id"], name: "index_wechat_notification_events_on_app_id"
    t.index ["status", "id"], name: "index_wechat_notification_events_on_status_and_id"
  end

  create_table "wechat_plugin_updates", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.boolean "confirmed", default: false, null: false
    t.datetime "created_at", null: false
    t.string "plugin_appid", null: false
    t.datetime "updated_at", null: false
    t.string "version", null: false
    t.index ["app_id", "plugin_appid"], name: "index_wechat_plugin_updates_on_app_id_and_plugin_appid", unique: true
    t.index ["app_id"], name: "index_wechat_plugin_updates_on_app_id"
  end

  create_table "wechat_violations", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.text "content"
    t.datetime "created_at", null: false
    t.datetime "occurred_at", null: false
    t.text "reason"
    t.string "record_number", null: false
    t.text "rule_name"
    t.text "rule_url"
    t.datetime "updated_at", null: false
    t.index ["app_id", "record_number"], name: "index_wechat_violations_on_app_id_and_record_number", unique: true
    t.index ["app_id"], name: "index_wechat_violations_on_app_id"
    t.index ["occurred_at", "id"], name: "index_wechat_violations_on_occurred_at_and_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "app_authorizations", "admins", column: "initiator_id"
  add_foreign_key "app_authorizations", "apps"
  add_foreign_key "apps", "open_platform_accounts"
  add_foreign_key "links", "apps", on_delete: :restrict
  add_foreign_key "location_interface_applications", "admins", column: "operator_id"
  add_foreign_key "location_interface_applications", "apps"
  add_foreign_key "mini_program_audits", "admins", column: "operator_id"
  add_foreign_key "mini_program_audits", "apps"
  add_foreign_key "mini_program_audits", "mini_program_releases", on_delete: :nullify
  add_foreign_key "mini_program_releases", "admins", column: "operator_id"
  add_foreign_key "mini_program_releases", "apps"
  add_foreign_key "mini_program_releases", "mini_program_releases", column: "previous_build_id", on_delete: :nullify
  add_foreign_key "mini_program_releases", "mini_program_releases", column: "source_release_id", on_delete: :nullify
  add_foreign_key "official_account_callbacks", "apps"
  add_foreign_key "official_account_fan_events", "apps"
  add_foreign_key "official_account_fan_syncs", "admins", column: "operator_id"
  add_foreign_key "official_account_fan_syncs", "apps"
  add_foreign_key "official_account_fans", "user_apps"
  add_foreign_key "official_account_menus", "apps"
  add_foreign_key "official_account_qrcodes", "apps"
  add_foreign_key "open_platform_accounts", "admins", column: "operator_id"
  add_foreign_key "open_platform_accounts", "apps", column: "created_via_app_id"
  add_foreign_key "open_platform_operations", "apps"
  add_foreign_key "open_platform_operations", "open_platform_accounts"
  add_foreign_key "posters", "apps"
  add_foreign_key "posters", "official_account_qrcodes"
  add_foreign_key "user_apps", "apps", column: ["provider", "appid"], primary_key: ["provider", "appid"]
  add_foreign_key "user_apps", "users"
  add_foreign_key "wechat_appeals", "wechat_violations"
  add_foreign_key "wechat_category_acceptances", "apps", on_delete: :cascade
  add_foreign_key "wechat_link_operations", "apps"
  add_foreign_key "wechat_link_operations", "apps", column: "mini_program_id"
  add_foreign_key "wechat_notification_events", "apps"
  add_foreign_key "wechat_plugin_updates", "apps", on_delete: :cascade
  add_foreign_key "wechat_violations", "apps"
end
