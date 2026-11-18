module Admins
  class OperationLogsController < BaseController
    before_action :require_super_admin!

    def index
      scope = Log.order(created_at: :desc, id: :desc)
      @action = params[:operation].to_s
      scope = scope.where(action: @action) if @action.present?
      @pagy, @logs = pagy(scope)
      @list_context = { operation: @action.presence, page: (@pagy.page if @pagy.page > 1) }.compact
      @actors = Admin.where(id: @logs.select(&:actor_id).map(&:actor_id)).index_by(&:id)
    end

    def show
      @log = Log.find(params[:id])
      @actor = Admin.find_by(id: @log.actor_id) if @log.actor_type == "Admin"
      @list_context = params.permit(:operation, :page).to_h
    end
  end
end
