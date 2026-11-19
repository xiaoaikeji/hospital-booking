class RestoreWechatLinkTargetReference < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:wechat_link_operations, :mini_program_id)
      add_column :wechat_link_operations, :mini_program_id, :bigint
    end
    add_index :wechat_link_operations, :mini_program_id, if_not_exists: true
    unless foreign_key_exists?(:wechat_link_operations, :apps, column: :mini_program_id)
      add_foreign_key :wechat_link_operations, :apps, column: :mini_program_id
    end
    execute <<~SQL
      UPDATE wechat_link_operations AS op
      SET mini_program_id = apps.id
      FROM apps
      WHERE op.mini_program_id IS NULL AND apps.appid = op.mini_appid
        AND apps.provider = 'wechat' AND apps.app_type = 'mini_program'
    SQL
  end

  # This reference also belongs to the original relationship migration.
  def down
  end
end
