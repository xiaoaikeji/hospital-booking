class CreateNotifications < ActiveRecord::Migration[8.1]
  def change
    create_table :notifications do |t|
      t.string :event, limit: 100, null: false
      t.string :subject_type, limit: 50, null: false
      t.bigint :subject_id, null: false
      t.string :status, limit: 20, null: false
      t.integer :attempt_count, null: false, default: 0
      t.string :idempotency_key, limit: 150
      t.jsonb :payload, null: false, default: {}
      t.jsonb :response_data, null: false, default: {}
      t.text :error_message
      t.string :job_id, limit: 100
      t.timestamptz :scheduled_at
      t.timestamptz :last_attempt_at
      t.timestamptz :sent_at
      t.timestamps type: :timestamptz
    end
    add_index :notifications, :idempotency_key, unique: true
    add_index :notifications, [ :status, :scheduled_at ]
    add_index :notifications, [ :subject_type, :subject_id ]
    add_index :notifications, :event
    add_check_constraint :notifications, "status IN ('pending','sending','sent','failed')", name: "notifications_status_valid"
    add_check_constraint :notifications, "attempt_count >= 0", name: "notifications_attempts_valid"
    add_check_constraint :notifications, "jsonb_typeof(payload) = 'object' AND jsonb_typeof(response_data) = 'object'", name: "notifications_objects_required"
  end
end
