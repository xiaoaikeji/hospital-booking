module Admins
  class AppPrivacySettingsController < WechatAppManagementController
    def edit
      @privacy = WechatPlatform::PrivacySettings.new(@app).read
      @revision = @privacy.revision
      @owner = @privacy.owner
      @entries = @privacy.entries
    rescue WechatPlatform::Error, HttpConnection::Unavailable, Wechat::BaseClient::Rejected => error
      redirect_to admins_app_path(@app, helpers.application_context_params.merge(tab: "privacy")), alert: error.message
    end

    def update
      input = params.require(:privacy).permit(:revision, owner: WechatPlatform::PrivacySettings::OWNER_FIELDS.keys,
        entries: %i[key enabled purpose]).to_h
      raise ActionController::BadRequest unless input["owner"].is_a?(Hash) && input.fetch("entries", {}).is_a?(Hash)
      service = WechatPlatform::PrivacySettings.new(@app)
      service.apply!(input, actor: current_admin, request: request)
      redirect_to admins_app_path(@app, helpers.application_context_params.merge(tab: "privacy")), notice: "微信开发版隐私指引已更新", status: :see_other
    rescue WechatPlatform::Error, HttpConnection::Unavailable, Wechat::BaseClient::Rejected => error
      @privacy = service.last_read
      @revision = input["revision"]
      @entries = input.fetch("entries", {}).values
      @owner = input.fetch("owner", {})
      if error.is_a?(WechatPlatform::PrivacySettings::InvalidField)
        @field_error = error
      else
        flash.now[:alert] = error.message
      end
      render :edit, status: :unprocessable_content
    end
  end
end
