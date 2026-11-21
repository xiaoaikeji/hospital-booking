class AddSessionsToUserApps < ActiveRecord::Migration[8.1]
  def change
    add_column :user_apps, :sessions, :jsonb, default: {}, null: false
    add_check_constraint :user_apps, "jsonb_typeof(sessions) = 'object'", name: "user_app_sessions_object"
  end
end
