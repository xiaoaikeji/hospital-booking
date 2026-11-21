module Admins
  class PluginsController < BaseController
    before_action :require_super_admin!

    def index
      @apps = App.wechat_mini_programs.order(:nickname, :id)
      return if params[:app_id].blank?

      @app = @apps.find(params[:app_id])
      @plugins = Wechat::AppPlugins.new(@app).list
    rescue Wechat::Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable => error
      @load_error = error.message
    end
  end
end
