module Admins
  class IllegalRecordsController < BaseController
    before_action :require_super_admin!

    def index
      @apps = App.wechat_mini_programs.order(:nickname, :id)
      @app = @apps.find(params[:app_id]) if params[:app_id].present?
      scope = @app ? @app.wechat_violations : WechatViolation.where(app: @apps)
      @pagy, @records = pagy(scope.includes(:app, :appeals).order(occurred_at: :desc, id: :desc))
      @delivery = WechatNotificationEvent.where(event_key: @records.map { |record| "violation:#{record.id}" }).pluck(:event_key, :status).to_h
    end
  end
end
