class TrackWechatManagementRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :wechat_category_acceptances do |t|
      t.references :app, null: false, foreign_key: { on_delete: :cascade }
      t.integer :first_category, null: false
      t.integer :second_category, null: false
      t.timestamps
      t.index [:app_id, :first_category, :second_category], unique: true
    end

    create_table :wechat_plugin_updates do |t|
      t.references :app, null: false, foreign_key: { on_delete: :cascade }
      t.string :plugin_appid, null: false
      t.string :version, null: false
      t.boolean :confirmed, null: false, default: false
      t.timestamps
      t.index [:app_id, :plugin_appid], unique: true
    end

    reversible { |dir| dir.up { backfill_from_logs } }
  end

  def backfill_from_logs
    # The old audit trail identifies acceptance but not subsequent external removal.
    # Pulling the live list or confirming the result settles these historical entries.
    execute <<~SQL
      INSERT INTO wechat_category_acceptances (app_id, first_category, second_category, created_at, updated_at)
      SELECT target_id, first_id, second_id, created_at, created_at
      FROM (
        SELECT DISTINCT ON (l.target_id, (l.details->>'first'), (l.details->>'second'))
          l.target_id, l.action, (l.details->>'first')::int AS first_id,
          (l.details->>'second')::int AS second_id, l.created_at
        FROM logs l JOIN apps a ON a.id = l.target_id
        WHERE l.target_type = 'App' AND l.category = 'wechat' AND l.status = 'success'
          AND l.action IN ('wechat.category_add', 'wechat.category_delete')
          AND l.details->>'first' ~ '^[0-9]{1,9}$' AND l.details->>'second' ~ '^[0-9]{1,9}$'
        ORDER BY l.target_id, (l.details->>'first'), (l.details->>'second'), l.id DESC
      ) latest WHERE action = 'wechat.category_add'
      ON CONFLICT (app_id, first_category, second_category) DO NOTHING
    SQL

    execute <<~SQL
      INSERT INTO wechat_plugin_updates (app_id, plugin_appid, version, confirmed, created_at, updated_at)
      SELECT target_id, plugin, version, status = 'success', created_at, created_at
      FROM (
        SELECT DISTINCT ON (l.target_id, (l.details->>'plugin_appid'))
          l.target_id, l.action, l.status, l.details->>'plugin_appid' AS plugin,
          l.details->>'version' AS version, l.created_at
        FROM logs l JOIN apps a ON a.id = l.target_id
        WHERE l.target_type = 'App' AND l.category = 'wechat'
          AND l.details->>'plugin_appid' ~ '^[A-Za-z0-9_]{1,64}$'
          AND ((l.action IN ('wechat.plugin_apply','wechat.plugin_unbind') AND l.status = 'success')
            OR (l.action = 'wechat.plugin_update' AND char_length(l.details->>'version') BETWEEN 1 AND 32
              AND (l.status = 'success' OR l.details->>'reason' = '微信尚未确认本次插件操作，请先核实当前插件状态')))
        ORDER BY l.target_id, (l.details->>'plugin_appid'), l.id DESC
      ) latest WHERE action = 'wechat.plugin_update'
      ON CONFLICT (app_id, plugin_appid) DO NOTHING
    SQL
  end
end
