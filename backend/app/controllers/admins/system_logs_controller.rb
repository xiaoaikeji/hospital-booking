module Admins
  class SystemLogsController < BaseController
    before_action :require_super_admin!

    def index
      scope = Log.where(source: "system", category: "payment", action: "wechat_pay.gateway_error")
        .or(Log.where(source: "user", category: "booking", action: "appointment.create", target_id: nil, status: "failed"))
        .or(Log.where(source: "console", category: "security", action: "admin.create"))
      @filters = params.permit(:date_range, :source, :status).to_h.symbolize_keys.compact_blank
      scope = scope.where(@filters.slice(:source, :status))
      days = list_date_range(@filters[:date_range])
      scope = scope.where(created_at: days.begin.in_time_zone..) if days.begin
      scope = scope.where(created_at: ...days.end.tomorrow.in_time_zone) if days.end
      @pagy, @logs = pagy(scope.order(created_at: :desc, id: :desc))
    end
  end
end
