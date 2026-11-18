module Admins
  class OperationLogsController < BaseController
    STATUSES = { "success" => "成功", "failed" => "失败" }.freeze

    def index
      scope = Log.operations_visible_to(current_admin)
      @filters = filter_params
      if current_admin.super_admin?
        @actor_options = Admin.where(id: scope.where(actor_type: "Admin").select(:actor_id)).order(:username)
        scope = scope.where(actor_type: "Admin", actor_id: @filters[:actor_id]) if @filters[:actor_id]
      end
      scope = scope.where(action: @filters[:operation]) if @filters[:operation]
      scope = scope.where(status: @filters[:status]) if @filters[:status]
      scope = scope.where(created_at: day_start(@filters[:from])..) if @filters[:from]
      scope = scope.where(created_at: ...day_start(@filters[:to]).tomorrow) if @filters[:to]

      @pagy, @logs = pagy(scope.order(created_at: :desc, id: :desc))
      @list_context = @filters.merge(page: (@pagy.page if @pagy.page > 1)).compact
      @actors = Admin.where(id: @logs.filter_map { |log| log.actor_id if log.actor_type == "Admin" }).index_by(&:id)
    end

    def show
      @log = Log.operations_visible_to(current_admin).find(params[:id])
      @actor = Admin.find_by(id: @log.actor_id) if @log.actor_type == "Admin"
      @list_context = filter_params.merge(params.permit(:page).to_h)
    end

    private

    def filter_params
      keys = %i[operation status from to]
      keys << :actor_id if current_admin.super_admin?
      params.permit(*keys).to_h.compact_blank
    end

    def day_start(value)
      raise ActionController::BadRequest, "日期格式无效" unless /\A\d{4}-\d{2}-\d{2}\z/.match?(value.to_s)

      Date.iso8601(value).in_time_zone
    rescue Date::Error
      raise ActionController::BadRequest, "日期格式无效"
    end
  end
end
