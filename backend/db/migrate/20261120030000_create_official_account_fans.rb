class CreateOfficialAccountFans < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :user_no, null: false, limit: 8, index: { unique: true }
      t.string :platform, null: false
      t.string :nickname, limit: 100
      t.string :avatar_url, limit: 500
      t.string :mobile, limit: 30
      t.datetime :mobile_verified_at
      t.string :status, default: "active", null: false
      t.datetime :last_login_at
      t.timestamps
      t.check_constraint "platform IN ('wechat', 'douyin') AND status IN ('active', 'disabled') AND user_no ~ '^[1-9][0-9]{7}$'", name: "valid_terminal_user"
    end

    create_table :user_apps do |t|
      t.references :user, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :appid, null: false, limit: 100
      t.string :openid, null: false, limit: 150
      t.string :unionid, limit: 150
      t.string :status, default: "active", null: false
      t.integer :sign_in_count, default: 0, null: false
      t.datetime :last_sign_in_at
      t.timestamps
      t.index %i[provider appid openid], unique: true
      t.index %i[user_id provider appid], unique: true
      t.index %i[provider unionid]
      t.check_constraint "status IN ('active', 'disabled') AND sign_in_count >= 0", name: "valid_user_app"
    end
    add_foreign_key :user_apps, :apps, column: %i[provider appid], primary_key: %i[provider appid]

    create_table :official_account_fans do |t|
      t.references :user_app, null: false, foreign_key: true, index: { unique: true }
      t.boolean :subscribed, null: false
      t.datetime :subscribed_at
      t.datetime :unsubscribed_at
      t.string :scene
      t.string :qr_scene
      t.datetime :observed_at, null: false
      t.datetime :event_at
      t.timestamps
    end

    create_table :official_account_fan_syncs do |t|
      t.references :app, null: false, foreign_key: true
      t.references :operator, null: false, foreign_key: { to_table: :admins }
      t.string :state, default: "queued", null: false
      t.string :error
      t.integer :fan_count
      t.timestamps
      t.index :app_id, unique: true, where: "state IN ('queued', 'running')", name: "one_active_fan_sync"
    end
  end
end
