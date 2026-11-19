class StoreWechatAuditFeedback < ActiveRecord::Migration[8.1]
  def change
    add_column :mini_program_audits, :rejection_reason, :text
    add_column :mini_program_audits, :rejection_screenshots, :text, array: true, default: [], null: false
  end
end
