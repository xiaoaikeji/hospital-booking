module Admins
  class SystemSettings::WecomNotificationsController < BaseController
    before_action :require_super_admin!

    before_action { response.headers["Cache-Control"] = "private, no-store" }

    def edit
      @settings = Notifications::WecomSettings.new
    end

    def update
      @settings = Notifications::WecomSettings.new
      input = params.require(:notification_settings).permit(:revision, :webhook_key, :same_robot, :clear_key)
      clearing = input[:clear_key] == "1"
      if @settings.save(input, actor: current_admin, request: request)
        redirect_to edit_admins_system_settings_wecom_notifications_path, status: :see_other,
          notice: (clearing ? "系统配置已清除" : "企微通知设置已保存")
      else
        @input = input unless clearing
        render :edit, status: :unprocessable_content
      end
    end
  end
end
