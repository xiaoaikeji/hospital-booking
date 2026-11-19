class RecordWechatSubmissionWindow < ActiveRecord::Migration[8.1]
  def change
    add_column :mini_program_audits, :submission_finished_at, :datetime
  end
end
