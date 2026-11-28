class IndexBookingHistoryAndReceipts < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :logs, %i[target_type target_id created_at id], name: "index_logs_on_target_history", algorithm: :concurrently
    add_index :logs, %i[actor_type actor_id created_at id], name: "index_logs_on_actor_history", algorithm: :concurrently
    add_index :appointments, %i[paid_at id], order: { paid_at: "DESC NULLS LAST", id: :desc },
      where: "payment_channel = 'wechat_jsapi' AND payment_status = 'paid'",
      name: "index_appointments_on_wechat_receipts", algorithm: :concurrently
  end
end
