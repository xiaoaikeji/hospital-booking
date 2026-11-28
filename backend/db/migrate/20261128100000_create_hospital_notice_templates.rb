class CreateHospitalNoticeTemplates < ActiveRecord::Migration[8.1]
  def up
    create_table :hospital_notice_templates do |t|
      t.string :event, null: false
      t.string :name, null: false
      t.jsonb :messages, null: false
      t.boolean :enabled, null: false, default: false
      t.integer :generation, null: false, default: 0
      t.timestamps
      t.index :event, unique: true, where: "enabled"
    end

    execute <<~SQL
      INSERT INTO hospital_notice_templates (event, name, messages, enabled, generation, created_at, updated_at)
      SELECT events.event, events.label, settings->'messages', COALESCE((settings->>'enabled')::boolean, false),
             COALESCE((settings->>'generation')::integer, 0), created_at, updated_at
      FROM settings JOIN (VALUES
        ('appointment_confirmed', '预约成功'), ('return_requested', '退号待审核'),
        ('appointment_returned', '退号已办理'), ('unpaid_cancelled', '患者取消待支付预约'),
        ('refund_attention', '退款失败需处理')
      ) AS events(event, label) ON settings.key = 'hospital_notice.' || events.event
      WHERE jsonb_typeof(settings->'messages') = 'array'
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Multiple named templates cannot be represented by one legacy setting"
  end
end
