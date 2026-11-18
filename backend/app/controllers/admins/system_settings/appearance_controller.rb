module Admins
  class SystemSettings::AppearanceController < BaseController
    # 先完成登录和角色校验，存储配置异常时无权访问者仍收到 403。
    before_action :require_super_admin!, :refresh_storage_configuration

    def edit
      @settings = AppearanceSettings.new
    end

    def update
      @settings = AppearanceSettings.new
      input = params.require(:appearance)
      raise ActionController::BadRequest unless input.is_a?(ActionController::Parameters)
      if @settings.save(input.to_unsafe_h, expected_revision: params[:revision], actor: current_admin, request: request)
        redirect_to edit_admins_system_settings_appearance_path, notice: "全后台默认外观已保存", status: :see_other
      else
        render :edit, status: :unprocessable_content
      end
    end
  end
end
