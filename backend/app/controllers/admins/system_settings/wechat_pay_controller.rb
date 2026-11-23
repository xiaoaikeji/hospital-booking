module Admins
  class SystemSettings::WechatPayController < BaseController
    before_action :require_super_admin!, :refresh_storage_configuration

    def edit
      @settings = WechatPaySettings.new
    end

    def update
      @settings = WechatPaySettings.new
      input = params.expect(wechat_pay: [ :revision, :clear_settings, :remove_v2_certificate, :remove_backup, *WechatPaySettings::LABELS.keys ])
      if @settings.save(input.to_h, actor: current_admin, request: request)
        redirect_to edit_admins_system_settings_wechat_pay_path, notice: "微信支付设置已保存", status: :see_other
      else
        @submitted = input
        render :edit, status: :unprocessable_content
      end
    end
  end
end
