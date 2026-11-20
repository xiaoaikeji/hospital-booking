class CreateOfficialAccountCallbacks < ActiveRecord::Migration[8.1]
  def change
    create_table :official_account_callbacks do |t|
      t.references :app, null: false, foreign_key: true
      t.string :digest, null: false
      t.string :sender_digest, null: false
      t.text :message, null: false
      t.text :reply_xml
      t.timestamptz :processed_at
      t.timestamps type: :timestamptz
    end
    add_index :official_account_callbacks, [ :app_id, :digest ], unique: true
    add_index :official_account_callbacks, [ :app_id, :sender_digest ]
  end
end
