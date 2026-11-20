class CreateOfficialAccountFanEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :official_account_fan_events do |t|
      t.references :app, null: false, foreign_key: true
      t.string :digest, null: false
      t.text :openid, null: false
      t.string :event, null: false
      t.datetime :occurred_at, null: false
      t.string :qr_scene
      t.index %i[app_id digest], unique: true
    end
  end
end
