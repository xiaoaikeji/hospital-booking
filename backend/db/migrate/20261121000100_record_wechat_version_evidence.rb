class RecordWechatVersionEvidence < ActiveRecord::Migration[8.1]
  def change
    add_column :mini_program_audits, :publication_attempt, :jsonb
    add_column :mini_program_releases, :prior_experience, :jsonb
  end
end
