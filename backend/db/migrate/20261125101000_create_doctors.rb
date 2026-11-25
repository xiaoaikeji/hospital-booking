class CreateDoctors < ActiveRecord::Migration[8.1]
  def change
    create_table :doctors do |t|
      t.string :name, limit: 100, null: false
      t.string :main_title, limit: 100
      t.text :description
      t.text :good_in
      t.text :introduction
      t.decimal :fee, precision: 10, scale: 2, default: 0, null: false
      t.integer :status, limit: 2, default: 1, null: false
      t.integer :sort_order, default: 0, null: false
      t.boolean :recommend, default: false, null: false
      t.boolean :display_on_homepage, default: true, null: false
      t.integer :max_total_bookings
      t.integer :max_bookings_per_slot
      t.string :mobile, limit: 30
      t.timestamptz :deleted_at
      t.timestamps type: :timestamptz

      t.check_constraint "fee >= 0", name: "doctors_fee_nonnegative"
      t.check_constraint "status IN (0, 1)", name: "doctors_status_allowed"
    end

    create_table :doctor_departments do |t|
      t.references :doctor, null: false, foreign_key: true, index: false
      t.references :department, null: false, foreign_key: true
      t.timestamps type: :timestamptz

      t.index %i[doctor_id department_id], unique: true
    end
  end
end
