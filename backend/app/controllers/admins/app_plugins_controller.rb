module Admins
  class AppPluginsController < BaseController
    before_action :require_super_admin!
    before_action { @app = App.wechat_mini_programs.find(params[:app_id]) }

    def create
      change("apply", params[:plugin_appid], "已提交插件使用申请") { |id| service.apply(id) }
    end

    def update
      version = params[:user_version].to_s.strip
      change("update", params[:id], "微信已确认插件版本更新", version: version) { |id| service.update(id, version) }
    end

    def verify
      version = params[:actual_version].to_s.strip
      change("verify", params[:id], "已登记插件当前版本", version: version) do |id|
        service.verify(id, params[:operation_id], params[:confirmed], version)
      end
    end

    def destroy
      change("unbind", params[:id], "微信已确认解除插件") { |id| service.unbind(id) }
    end

    private

    def service = Wechat::AppPlugins.new(@app)

    def change(action, appid, notice, version: nil)
      id = appid.to_s.strip
      details = {}
      details[:plugin_appid] = id if Wechat::MiniProgramPluginClient::PLUGIN_APPID.match?(id)
      details[:version] = version if version.present? && version.length <= 32
      yield id
      Wechat.log!(@app, "plugin_#{action}", actor: current_admin, request: request, details: details)
      redirect_to plugin_path, notice: notice, status: :see_other
    rescue Wechat::Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable => error
      Wechat.log!(@app, "plugin_#{action}", actor: current_admin, request: request, status: "failed",
        details: details.merge(reason: error.message))
      flash[:plugin_form] = { app_id: @app.id, action: action, id: id.first(64), version: version&.first(32) }
      redirect_to plugin_path, alert: error.message, status: :see_other
    end

    def plugin_path = admins_app_path(@app, helpers.application_context_params.merge(tab: "plugins"))
  end
end
