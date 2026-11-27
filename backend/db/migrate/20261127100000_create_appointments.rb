class CreateAppointments < ActiveRecord::Migration[8.1]
  def change
    create_table :appointments do |t|
      t.string :order_no, limit: 40, null: false
      t.string :idempotency_key, limit: 64, null: false
      t.references :user, null: false, foreign_key: true, index: false
      t.references :patient, foreign_key: { on_delete: :nullify }
      t.references :doctor, null: false, foreign_key: true, index: false
      t.references :department, null: false, foreign_key: true
      t.string :source_platform, limit: 20, null: false
      t.string :source_appid, limit: 100, null: false
      t.string :status, limit: 30, null: false
      t.date :appointment_date, null: false
      t.string :time_slot, limit: 10, null: false
      t.timestamptz :booking_start_at
      t.timestamptz :booking_end_at
      t.string :slot_label, limit: 100, null: false
      t.string :patient_name, limit: 100, null: false
      t.integer :patient_age, null: false
      t.integer :patient_gender, limit: 2, null: false, default: 0
      t.string :patient_mobile, limit: 30, null: false
      t.string :doctor_name, limit: 100, null: false
      t.string :department_name, limit: 200, null: false
      t.jsonb :hospital_snapshot, null: false, default: {}
      t.text :remark
      t.bigint :fee_cents, null: false, default: 0
      t.bigint :discount_cents, null: false, default: 0
      t.bigint :payable_amount_cents, null: false, default: 0
      t.references :payer_user, foreign_key: { to_table: :users }
      t.string :payment_no, limit: 40
      t.string :payment_platform, limit: 20
      t.string :payment_appid, limit: 100
      t.string :payment_channel, limit: 30, null: false
      t.string :mch_id, limit: 100
      t.bigint :paid_amount_cents, null: false, default: 0
      t.string :payment_status, limit: 20, null: false, default: "unpaid"
      t.string :transaction_no, limit: 100
      t.timestamptz :payment_expires_at
      t.timestamptz :paid_at
      t.timestamptz :payment_closed_at
      t.bigint :refunded_amount_cents, default: 0
      t.string :refund_status, limit: 20, null: false, default: "none"
      t.jsonb :refund_data, null: false, default: {}
      t.timestamptz :cancel_requested_at
      t.timestamptz :cancelled_at
      t.timestamptz :completed_at
      t.timestamptz :deleted_at
      t.timestamps type: :timestamptz

      t.index :order_no, unique: true
      t.index :payment_no, unique: true
      t.index [ :user_id, :idempotency_key ], unique: true
      t.index [ :user_id, :appointment_date ]
      t.index [ :doctor_id, :appointment_date ]
      t.index :appointment_date
      t.check_constraint "source_platform IN ('wechat', 'douyin')", name: "appointments_source_platform_valid"
      t.check_constraint "status IN ('pending_payment', 'confirmed', 'cancel_requested', 'completed', 'cancelled')", name: "appointments_status_valid"
      t.check_constraint "time_slot IN ('FULL', 'AM', 'PM', 'NIGHT')", name: "appointments_time_slot_valid"
      t.check_constraint "booking_end_at > booking_start_at", name: "appointments_booking_window_valid"
      t.check_constraint "patient_age BETWEEN 1 AND 200 AND patient_gender IN (0, 1, 2)", name: "appointments_patient_valid"
      t.check_constraint "fee_cents >= 0 AND discount_cents >= 0 AND payable_amount_cents >= 0 AND paid_amount_cents >= 0", name: "appointments_amounts_valid"
      t.check_constraint "payment_platform IN ('wechat', 'douyin')", name: "appointments_payment_platform_valid"
      t.check_constraint "payment_channel IN ('wechat_jsapi', 'douyin', 'none')", name: "appointments_payment_channel_valid"
      t.check_constraint "payment_status IN ('unpaid', 'paid', 'closed')", name: "appointments_payment_status_valid"
      t.check_constraint "refunded_amount_cents BETWEEN 0 AND paid_amount_cents", name: "appointments_refunded_amount_valid"
      t.check_constraint "refund_status IN ('none', 'requested', 'approved', 'rejected', 'processing', 'partial', 'refunded', 'failed')", name: "appointments_refund_status_valid"
      t.check_constraint "jsonb_typeof(refund_data) = 'object'", name: "appointments_refund_data_valid"
    end
  end
end
