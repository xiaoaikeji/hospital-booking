module Admins
  class SystemSettings::MapController < BaseController
    before_action :require_super_admin!, :refresh_storage_configuration

    def edit
      @settings = MapSettings.new
    end

    def update
      @settings = MapSettings.new
      input = params.expect(map: [ :revision, :provider, :ak, :tencent_key, :clear_key, :clear_settings ])
      if @settings.save(input, actor: current_admin, request: request)
        redirect_to edit_admins_system_settings_map_path, notice: "地图服务设置已保存", status: :see_other
      else
        render :edit, status: :unprocessable_content
      end
    end
  end
end
