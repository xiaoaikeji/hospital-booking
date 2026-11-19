class CreateLocationInterfaceApplications < ActiveRecord::Migration[8.1]
  def change
    create_table :location_interface_applications do |t|
      t.references :app, null: false, foreign_key: true
      t.references :operator, null: false, foreign_key: { to_table: :admins }
      t.string :api_name, null: false, limit: 100
      t.text :content, null: false
      t.string :state, null: false
      t.jsonb :previous_review, null: false
      t.string :audit_id
      t.integer :error_code
      t.timestamps
    end
    add_index :location_interface_applications, [:app_id, :api_name, :id]
  end
end
