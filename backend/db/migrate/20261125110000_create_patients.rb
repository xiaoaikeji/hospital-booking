class CreatePatients < ActiveRecord::Migration[8.1]
  def change
    create_table :patients do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, limit: 100, null: false
      t.integer :gender, limit: 2, default: 0, null: false
      t.integer :age, null: false
      t.string :phone, limit: 30
      t.timestamps type: :timestamptz

      t.check_constraint "gender IN (0, 1, 2)", name: "patients_gender_allowed"
      t.check_constraint "age BETWEEN 1 AND 200", name: "patients_age_range"
    end
  end
end
