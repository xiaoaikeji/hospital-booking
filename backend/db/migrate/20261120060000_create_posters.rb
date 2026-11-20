class CreatePosters < ActiveRecord::Migration[8.1]
  def change
    create_table :posters do |t|
      t.string :name, null: false
      t.string :target_kind
      t.references :app, foreign_key: true
      t.references :official_account_qrcode, foreign_key: true
      t.string :page_path
      t.string :page_query
      t.integer :image_width, null: false
      t.integer :image_height, null: false
      t.integer :qr_x, null: false
      t.integer :qr_y, null: false
      t.integer :qr_size, null: false
      t.timestamps
    end
  end
end
