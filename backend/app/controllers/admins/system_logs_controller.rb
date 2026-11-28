module Admins
  class SystemLogsController < BaseController
    SOURCES = Admins::RecordHistoryHelper::SYSTEM_SOURCES.slice("system", "user", "console").freeze
    STATUSES = Admins::OperationLogsController::STATUSES.slice("success", "failed").transform_values(&:first).freeze

    before_action :require_super_admin!

    def index
      scope = Log.where(source: "system", category: "payment", action: "wechat_pay.gateway_error")
        .or(Log.where(source: "user", category: "booking", action: "appointment.create", target_id: nil, status: "failed"))
        .or(Log.where(source: "console", category: "security", action: "admin.create"))
      @filters = params.permit(:date_range, :source, :status).to_h.symbolize_keys.compact_blank
      @filters.delete(:source) unless SOURCES.key?(@filters[:source])
      @filters.delete(:status) unless STATUSES.key?(@filters[:status])
      scope = scope.where(@filters.slice(:source, :status))
      days = list_date_range(@filters[:date_range])
      scope = scope.where(created_at: days.begin.in_time_zone..) if days.begin
      scope = scope.where(created_at: ...days.end.tomorrow.in_time_zone) if days.end
      @pagy, @logs = pagy(scope.order(created_at: :desc, id: :desc))
    end
  end
end
