class CreateDepartments < ActiveRecord::Migration[8.1]
  def change
    create_table :departments do |t|
      t.references :parent, foreign_key: { to_table: :departments }
      t.string :name, limit: 100, null: false
      t.string :icon_type, limit: 20
      t.string :icon, limit: 255
      t.text :position, array: true, default: [ "department" ], null: false
      t.integer :status, limit: 2, default: 1, null: false
      t.integer :sort_order, default: 0, null: false
      t.timestamps type: :timestamptz

      t.check_constraint "status IN (0, 1)", name: "departments_status_allowed"
    end
  end
end
