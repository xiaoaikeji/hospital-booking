class LinkWechatRestoredUploads < ActiveRecord::Migration[8.1]
  def change
    # 这是上传快照中的历史编号；原提审记录被删除后也保留恢复用途。
    add_column :mini_program_releases, :restored_for_id, :bigint
    add_index :mini_program_releases, [:app_id, :restored_for_id], where: "restored_for_id IS NOT NULL"
  end
end
