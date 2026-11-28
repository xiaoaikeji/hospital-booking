module Admins
  class NotificationsController < BaseController
    before_action :require_super_admin!

    def index
      case params[:view]
      when "hospital_skips"
        scope = Log.where(source: "system", action: "notification.hospital_skipped", target_type: "Appointment")
        @pagy, @hospital_skips = pagy(scope.order(id: :desc))
        @order_numbers = Appointment.current.where(id: @hospital_skips.map(&:target_id)).pluck(:id, :order_no).to_h
      when "interval_skips"
        scope = Log.where(source: "webhook", action: "notification.reply_interval_skipped", target_type: "App")
        @pagy, @interval_skips = pagy(scope.order(id: :desc))
        @accounts = App.wechat_official_accounts.where(id: @interval_skips.map(&:target_id)).index_by(&:id)
      else
        @pagy, @notifications = pagy(Notification.order(id: :desc))
      end
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
