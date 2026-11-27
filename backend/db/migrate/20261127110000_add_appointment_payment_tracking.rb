class AddAppointmentPaymentTracking < ActiveRecord::Migration[8.1]
  def change
    add_column :appointments, :payment_data, :jsonb, null: false, default: {}
    add_column :appointments, :payment_cancel_requested_at, :timestamptz
    add_reference :appointments, :completed_by_admin, foreign_key: { to_table: :admins }

    add_check_constraint :appointments, "jsonb_typeof(payment_data) = 'object'", name: "appointments_payment_data_valid"
    add_index :appointments, %i[payment_channel mch_id transaction_no], unique: true,
      where: "transaction_no IS NOT NULL", name: "index_appointments_on_channel_transaction"
    add_index :appointments, :payment_expires_at, where: "status = 'pending_payment'",
      name: "index_appointments_on_pending_payment_expiry"
    add_index :appointments, :refund_data, using: :gin, opclass: :jsonb_path_ops
    add_index :appointments, :refund_status, where: "refund_status IN ('approved', 'processing')",
      name: "index_appointments_on_pending_refunds"
  end
end
