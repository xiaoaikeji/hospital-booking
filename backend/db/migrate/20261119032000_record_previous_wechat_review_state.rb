class RecordPreviousWechatReviewState < ActiveRecord::Migration[8.1]
  def change
    add_column :mini_program_audits, :previous_audit_pending, :boolean
  end
end
