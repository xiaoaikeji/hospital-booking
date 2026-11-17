class CreateAdminsSettingsAndLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :admins do |t|
      t.string :username, limit: 100, null: false
      t.string :encrypted_password, null: false, default: ""
      t.string :name, limit: 100
      t.string :role, limit: 30, null: false, default: "operator"
      t.boolean :enabled, null: false, default: true
      t.datetime :remember_created_at
      t.integer :sign_in_count, null: false, default: 0
      t.datetime :current_sign_in_at
      t.datetime :last_sign_in_at
      t.inet :current_sign_in_ip
      t.inet :last_sign_in_ip
      t.timestamps
      t.index :username, unique: true
      t.check_constraint "role IN ('super_admin', 'operator', 'customer_service')", name: "admins_role_allowed"
    end
    create_table :settings do |t|
      t.string :key, limit: 100, null: false
      t.jsonb :settings, null: false, default: {}
      t.string :description, limit: 255
      t.timestamps
      t.index :key, unique: true
      t.check_constraint "jsonb_typeof(settings) = 'object'", name: "settings_object_required"
    end
    create_table :logs do |t|
      t.string :source, limit: 30, null: false
      t.string :category, limit: 50, null: false
      t.string :action, limit: 100, null: false
      t.string :status, limit: 20, null: false
      t.string :level, limit: 20, null: false, default: "info"
      t.string :actor_type, limit: 50
      t.bigint :actor_id
      t.string :target_type, limit: 100
      t.bigint :target_id
      t.string :summary, limit: 500
      t.jsonb :details, null: false, default: {}
      t.inet :ip_address
      t.text :user_agent
      t.string :request_id, limit: 100
      t.string :job_id, limit: 100
      t.string :correlation_id, limit: 100
      t.integer :duration_ms
      t.string :error_class, limit: 150
      t.text :error_message
      t.datetime :created_at, null: false
      %i[source category action request_id job_id correlation_id created_at].each { |field| t.index field }
    end
  end
end
