module Admins
  class AppPluginsController < WechatAppManagementController
    def create
      change("apply", params[:plugin_appid], "已提交插件使用申请") { |id| service.apply(id) }
    end

    def update
      version = params[:user_version].to_s.strip
      change("update", params[:id], "微信已确认插件版本更新", version: version) { |id| service.update(id, version) }
    end

    def destroy
      change("unbind", params[:id], "微信已确认解除插件") { |id| service.unbind(id) }
    end

    private

    def service = WechatPlatform::AppPlugins.new(@app)

    def change(action, appid, notice, version: nil)
      id = appid.to_s.strip
      details = {}
      details[:plugin_appid] = id if Wechat::MiniProgramPluginClient::PLUGIN_APPID.match?(id)
      details[:version] = version if version.present? && version.length <= 32
      perform_wechat_change("plugin_#{action}", tab: "plugins", notice: notice, details: details) do
        yield id
      rescue WechatPlatform::Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable
        flash[:plugin_form] = { app_id: @app.id, action: action, id: id.first(64), version: version&.first(32) }
        raise
      end
    end
  end
end
