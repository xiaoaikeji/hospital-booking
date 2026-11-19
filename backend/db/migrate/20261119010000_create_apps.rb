class CreateApps < ActiveRecord::Migration[8.1]
  def change
    create_table :apps do |t|
      t.string :provider, null: false
      t.string :appid, null: false
      t.string :nickname
      t.text :memo
      t.text :appsecret
      t.string :status, null: false, default: "disabled"
      t.string :verified_digest
      t.integer :lock_version, null: false, default: 0
      t.timestamps
      t.index %i[provider appid], unique: true
      t.check_constraint "provider IN ('wechat','douyin')", name: "apps_provider_valid"
      t.check_constraint "status IN ('active','auditing','disabled')", name: "apps_status_valid"
    end
  end
end
