module Admins
  class OperationLogsController < BaseController
    STATUSES = {
      "started" => [ "已开始", "info" ],
      "success" => [ "成功", "success" ],
      "failed" => [ "失败", "danger" ],
      "skipped" => [ "已跳过", "secondary" ]
    }.freeze

    def index
      @status_options = STATUSES.transform_values(&:first)
      scope = Log.operations_visible_to(current_admin)
      @filters = filter_params
      if current_admin.super_admin?
        @actor_options = Admin.where(id: scope.where(actor_type: "Admin").select(:actor_id)).order(:username)
        scope = scope.where(actor_type: "Admin", actor_id: @filters[:actor_id]) if @filters[:actor_id]
      end
      scope = scope.where(action: @filters[:operation]) if @filters[:operation]
      scope = scope.where(status: @filters[:status]) if @filters[:status]
      # 旧筛选链接可能只指定起始或截止日。
      @date_range = @filters[:date_range]
      if @date_range.nil? && (@filters[:from] || @filters[:to])
        @date_range = [ @filters[:from], @filters[:to] ].join(" – ")
      end
      days = list_date_range(@date_range)
      scope = scope.where(created_at: days.begin.in_time_zone..) if days.begin
      scope = scope.where(created_at: ...days.end.tomorrow.in_time_zone) if days.end

      @pagy, @logs = pagy(scope.order(created_at: :desc, id: :desc))
      @list_context = @filters.merge(page: (@pagy.page if @pagy.page > 1)).compact
      @actors = Admin.where(id: @logs.filter_map { |log| log.actor_id if log.actor_type == "Admin" }).index_by(&:id)
    end

    def show
      @log = Log.operations_visible_to(current_admin).find(params[:id])
      @details = OperationLogDetails.for(@log)
      @actor = Admin.find_by(id: @log.actor_id) if @log.actor_type == "Admin"
      @list_context = filter_params.merge(params.permit(:page).to_h)
    end

    private

    def filter_params
      keys = %i[operation status date_range from to]
      keys << :actor_id if current_admin.super_admin?
      params.permit(*keys).to_h.compact_blank
    end
  end
end
