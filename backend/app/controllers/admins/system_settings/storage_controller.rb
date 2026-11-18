module Admins
  class SystemSettings::StorageController < BaseController
    # 配置有误时仍可进入此页修正，避免错误配置堵住维护入口。
    skip_before_action :refresh_storage_configuration
    before_action :require_super_admin!

    def edit
      @settings = StorageSettings.new
    end

    def update
      @settings = StorageSettings.new
      submitted = params[:storage_settings]
      input = submitted.to_unsafe_h if submitted.is_a?(ActionController::Parameters) && submitted.present?
      revision = input&.delete("revision").to_s
      if @settings.save(input, actor: current_admin, request: request, expected_revision: revision)
        if @settings.refresh_warning
          flash[:alert] = @settings.refresh_warning
        else
          flash[:notice] = input["clear_fields"].present? ? "系统配置已清除" : "存储配置已保存"
        end
        redirect_to edit_admins_system_settings_storage_path, status: :see_other
      elsif input.nil?
        head :bad_request
      else
        render :edit, status: :unprocessable_content
      end
    end
  end
end
