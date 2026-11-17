module Admins
  class SystemSettingsController < BaseController
    # 配置有误时仍可进入此页修正，避免错误配置堵住维护入口。
    skip_before_action :refresh_storage_configuration
    before_action :require_super_admin!

    def edit
      @settings = StorageSettings.new
    end

    def update
      @settings = StorageSettings.new
      input = params.require(:storage_settings)
      raise ActionController::BadRequest unless input.is_a?(ActionController::Parameters)
      revision = input.delete(:revision).to_s
      if @settings.save(input.to_unsafe_h, actor: current_admin, request: request, expected_revision: revision)
        notice = input[:clear_fields].present? ? "系统配置已清除" : "存储配置已保存"
        redirect_to edit_admins_system_settings_path, notice: notice, status: :see_other
      else
        render :edit, status: :unprocessable_content
      end
    end
  end
end
