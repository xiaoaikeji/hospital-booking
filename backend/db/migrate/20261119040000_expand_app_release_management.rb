class ExpandAppReleaseManagement < ActiveRecord::Migration[8.1]
  def change
    add_column :apps, :app_type, :string, null: false, default: "mini_program"
    add_check_constraint :apps, "app_type = 'mini_program' OR (app_type = 'official_account' AND provider = 'wechat')", name: "apps_supported_type"
    add_column :mini_program_releases, :template_type, :string, null: false, default: "normal"
    add_column :mini_program_releases, :ext_config, :jsonb
    add_column :mini_program_audits, :approved_at, :datetime
    reversible do |dir|
      dir.up do
        execute <<~SQL
          UPDATE mini_program_releases r SET ext_config = jsonb_build_object(
            'extEnable', true, 'extAppid', a.appid, 'ext', jsonb_build_object('provider', a.provider, 'appid', a.appid))
          FROM apps a WHERE a.id = r.app_id
        SQL
      end
    end
  end
end
