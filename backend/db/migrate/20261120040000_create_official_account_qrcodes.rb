class CreateOfficialAccountQrcodes < ActiveRecord::Migration[8.1]
  def change
    create_table :official_account_qrcodes do |t|
      t.references :app, null: false, foreign_key: true
      t.string :name, null: false, limit: 60
      t.string :scene, null: false, limit: 64
      t.text :ticket, null: false
      t.text :url, null: false
      t.timestamps
      t.index %i[app_id scene], unique: true
    end
  end
end
