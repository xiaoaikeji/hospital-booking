module Admins
  class NotificationsController < BaseController
    before_action :require_super_admin!

    def index
      scope = Notification.order(id: :desc)
      @pagy, @notifications = pagy(scope)
    end

    def show
      @notification = Notification.find(params[:id])
    end

    def retry_failed
      row = Notification.find(params[:id])
      Notifications.retry_failed!(row, ids: params[:message_ids], actor: current_admin, request: request)
      redirect_to admins_notification_path(row), notice: "失败消息已安排补发", status: :see_other
    rescue Notifications::Error => error
      redirect_to admins_notification_path(row), alert: error.message, status: :see_other
    end
  end
end
