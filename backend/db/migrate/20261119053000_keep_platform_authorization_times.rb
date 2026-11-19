class KeepPlatformAuthorizationTimes < ActiveRecord::Migration[8.1]
  def up
    add_column :app_authorizations, :authorized_at, :datetime
    add_column :app_authorizations, :revoked_at, :datetime
    execute <<~SQL
      UPDATE app_authorizations a
      SET authorized_at = COALESCE((
        SELECT MAX(created_at) FROM logs WHERE target_type = 'App' AND target_id = a.app_id
          AND action = 'wechat.authorized' AND status = 'success' AND created_at <= COALESCE(a.event_at, a.updated_at) + INTERVAL '1 second'
      ), CASE WHEN refresh_token IS NOT NULL THEN event_at END),
      revoked_at = CASE WHEN refresh_token IS NULL THEN event_at END
    SQL
  end

  def down
    remove_column :app_authorizations, :authorized_at
    remove_column :app_authorizations, :revoked_at
  end
end
