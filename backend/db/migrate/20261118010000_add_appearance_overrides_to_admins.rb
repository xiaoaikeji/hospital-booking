class AddAppearanceOverridesToAdmins < ActiveRecord::Migration[8.1]
  def change
    add_column :admins, :appearance_overrides, :jsonb, default: {}, null: false
    add_check_constraint :admins, "jsonb_typeof(appearance_overrides) = 'object'", name: "admin_appearance_object_required"
  end
end
