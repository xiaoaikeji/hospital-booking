class CreateWechatReleaseRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :app_authorizations do |t|
      t.references :app, null: false, foreign_key: true, index: { unique: true }
      t.string :original_id
      t.text :refresh_token
      t.jsonb :scopes, null: false, default: []
      t.string :state_digest
      t.datetime :state_expires_at
      t.references :initiator, foreign_key: { to_table: :admins }
      t.datetime :event_at
      t.timestamps
    end
    create_table :mini_program_releases do |t|
      t.references :app, null: false, foreign_key: true
      t.references :operator, null: false, foreign_key: { to_table: :admins }
      t.string :template_id, null: false
      t.string :version, null: false
      t.text :description, null: false
      t.string :status, null: false, default: "upload_unknown"
      t.boolean :current_build, default: false, null: false
      t.index :app_id, unique: true, where: "current_build", name: "one_current_build_per_app"
      t.integer :error_code
      t.timestamps
    end
    create_table :mini_program_audits do |t|
      t.references :app, null: false, foreign_key: true
      t.references :mini_program_release, foreign_key: { on_delete: :nullify }
      t.references :operator, null: false, foreign_key: { to_table: :admins }
      t.string :version, null: false
      t.text :description, null: false
      t.string :previous_status, null: false
      t.string :previous_audit_id
      t.string :audit_id
      t.string :status, null: false, default: "submit_unknown"
      t.boolean :auto_publish, null: false, default: false
      t.string :prior_online_marker
      t.string :publication, null: false, default: "unpublished"
      t.integer :error_code
      t.timestamps
      t.index %i[app_id audit_id], unique: true
    end
  end
end
