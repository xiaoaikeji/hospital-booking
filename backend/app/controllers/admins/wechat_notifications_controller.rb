module Admins
  class WechatNotificationsController < BaseController
    before_action :require_super_admin!

    def index
      @apps = App.wechat_mini_programs.order(:nickname, :id)
      @app = @apps.find(params[:app_id]) if params[:app_id].present?
      scope = @app ? @app.wechat_notification_events : WechatNotificationEvent.where(app: @apps)
      @pagy, @events = pagy(scope.includes(:app, :delivery_task).order(id: :desc))
    end
  end
end
