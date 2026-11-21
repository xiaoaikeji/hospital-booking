class AddMiniProgramLoginContext < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :login_profile, :jsonb, default: {}, null: false
    add_column :user_apps, :first_entry, :jsonb, default: {}, null: false
    add_check_constraint :users, "jsonb_typeof(login_profile) = 'object'", name: "user_login_profile_object"
    add_check_constraint :user_apps, "jsonb_typeof(first_entry) = 'object'", name: "user_app_first_entry_object"
    add_index :users, :id, name: "users_pending_ip_location",
      where: "login_profile ? 'first_ip' AND NOT (login_profile ? 'region')"
  end
end
