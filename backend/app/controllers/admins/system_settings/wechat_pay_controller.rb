module Admins
  class SystemSettings::WechatPayController < BaseController
    before_action :require_super_admin!, :refresh_storage_configuration
    before_action :load_settings

    def edit
      @form_fields = @settings.form_fields
    end

    def update
      input = params.expect(wechat_pay: [ :revision, :clear_settings, :remove_v2_certificate, :remove_backup, *WechatPaySettings::LABELS.keys ])
      if @settings.save(input.to_h, actor: current_admin, request: request)
        redirect_to edit_admins_system_settings_wechat_pay_path, notice: "微信支付设置已保存", status: :see_other
      else
        draft = input.to_h if input[:revision] == @settings.revision
        @form_fields = @settings.form_fields(draft)
        @remove_backup = draft&.[]("remove_backup") == "1"
        render :edit, status: :unprocessable_content
      end
    end

    private

    def load_settings
      @settings = WechatPaySettings.new
      @gateway_error = Log.where(source: "system", category: "payment", action: "wechat_pay.gateway_error").order(id: :desc).first
    end
  end
end
