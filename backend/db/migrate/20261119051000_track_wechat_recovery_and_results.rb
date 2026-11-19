class TrackWechatRecoveryAndResults < ActiveRecord::Migration[8.1]
  def change
    add_reference :mini_program_releases, :source_release, foreign_key: { to_table: :mini_program_releases, on_delete: :nullify }
    add_reference :mini_program_releases, :previous_build, foreign_key: { to_table: :mini_program_releases, on_delete: :nullify }
    add_column :mini_program_releases, :audit_description, :text
    add_column :mini_program_audits, :published_at, :datetime
    add_column :mini_program_audits, :delay_reason, :text
  end
end
