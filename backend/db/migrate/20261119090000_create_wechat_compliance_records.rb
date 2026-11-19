class CreateWechatComplianceRecords < ActiveRecord::Migration[8.1]
  def change
    add_column :apps, :violations_synced_at, :datetime
    create_table :wechat_violations do |t|
      t.references :app, null: false, foreign_key: true
      t.string :record_number, null: false
      t.datetime :occurred_at, null: false
      t.text :reason, :content, :rule_name, :rule_url
      t.timestamps
      t.index [:app_id, :record_number], unique: true
      t.index [:occurred_at, :id]
    end
    create_table :wechat_appeals do |t|
      t.references :wechat_violation, null: false, foreign_key: true
      t.string :number, null: false
      t.integer :status, null: false
      t.datetime :appealed_at, :audited_at
      t.text :reason, :punishment
      t.timestamps
      t.index [:wechat_violation_id, :number], unique: true
    end
    create_table :wechat_notification_events do |t|
      t.references :app, null: false, foreign_key: true
      t.string :event_key, :kind, :status, null: false
      t.text :message, null: false
      t.integer :error_code
      t.timestamps
      t.index [:app_id, :event_key], unique: true
      t.index [:status, :id]
    end
  end
end
