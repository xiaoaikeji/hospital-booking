class CreateOfficialAccountMenus < ActiveRecord::Migration[8.1]
  def change
    create_table :official_account_menus do |t|
      t.references :app, null: false, foreign_key: true, index: { unique: true }
      t.jsonb :buttons, null: false, default: []
      t.jsonb :pending_buttons
      t.jsonb :observed_buttons
      t.integer :revision, null: false, default: 0
      t.timestamps
    end
  end
end
