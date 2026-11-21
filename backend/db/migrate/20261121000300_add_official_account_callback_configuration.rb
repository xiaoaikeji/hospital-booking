class AddOfficialAccountCallbackConfiguration < ActiveRecord::Migration[8.1]
  def change
    add_column :apps, :wechat_original_id, :string
    add_column :apps, :callback_token, :text
    add_column :apps, :callback_encoding_aes_key, :text
    add_index :apps, :wechat_original_id, unique: true, where: "wechat_original_id IS NOT NULL"

    reversible do |direction|
      direction.up do
        execute <<~SQL
          WITH verified AS (
            SELECT a.id, h.original_id, count(*) OVER (PARTITION BY h.original_id) AS matches
            FROM apps a JOIN app_authorizations h ON h.app_id = a.id
            WHERE a.provider = 'wechat' AND a.app_type = 'official_account'
              AND h.authorized_at IS NOT NULL AND h.original_id ~ '^gh_[a-zA-Z0-9_]{1,64}$'
          )
          UPDATE apps SET wechat_original_id = verified.original_id
          FROM verified WHERE apps.id = verified.id AND verified.matches = 1
        SQL
      end
    end
  end
end
