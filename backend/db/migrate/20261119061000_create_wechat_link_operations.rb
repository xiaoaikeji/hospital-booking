class CreateWechatLinkOperations < ActiveRecord::Migration[8.1]
  def change
    create_table :wechat_link_operations do |t|
      t.references :app, null: false, foreign_key: true
      t.references :mini_program, foreign_key: { to_table: :apps }
      t.string :mini_appid, null: false
      t.string :action, null: false
      t.string :state, null: false
      t.integer :previous_status
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :wechat_link_operations, [:app_id, :mini_appid], unique: true
  end
end
