module Admins
  class SystemSettings::WechatNotificationsController < BaseController
    before_action :require_super_admin!

    def edit
      @settings = WechatPlatform::NotificationSettings.new
    end

    def update
      @settings = WechatPlatform::NotificationSettings.new
      input = params.require(:notification_settings).permit(:revision, :webhook_key, :same_robot, :clear_key, :pull_violations, kinds: [])
      clearing = input[:clear_key] == "1"
      if @settings.save(input, actor: current_admin, request: request)
        redirect_to edit_admins_system_settings_wechat_notifications_path, status: :see_other,
          notice: (clearing ? "系统配置已清除" : "微信通知设置已保存")
      else
        @input = input unless clearing
        render :edit, status: :unprocessable_content
      end
    end
  end
end
