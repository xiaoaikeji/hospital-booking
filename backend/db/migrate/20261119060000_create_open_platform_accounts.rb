class CreateOpenPlatformAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :open_platform_accounts do |t|
      t.string :open_appid, null: false, limit: 60
      t.string :name, null: false, limit: 120
      t.references :created_via_app, null: false, foreign_key: { to_table: :apps }
      t.references :operator, null: false, foreign_key: { to_table: :admins }
      t.timestamps
    end
    add_index :open_platform_accounts, :open_appid, unique: true
    add_reference :apps, :open_platform_account, foreign_key: true

    # 写请求发送前登记，直至明确拒绝、明确成功或通过同步核实；审计长期保留在 logs。
    create_table :open_platform_operations do |t|
      t.references :app, null: false, foreign_key: true, index: { unique: true }
      t.references :open_platform_account, foreign_key: true
      t.string :action, null: false
      t.string :name, limit: 120
      t.timestamps
    end
    add_check_constraint :open_platform_operations,
      "(action = 'create' AND open_platform_account_id IS NULL) OR (action IN ('bind', 'unbind') AND open_platform_account_id IS NOT NULL)",
      name: "valid_open_platform_operation"
  end
end
