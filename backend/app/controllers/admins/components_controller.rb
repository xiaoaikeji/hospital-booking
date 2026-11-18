module Admins
  class ComponentsController < BaseController
    GROUPS = {
      "media" => "图片与附件",
      "forms" => "输入与校验",
      "selection" => "选择与开关",
      "records" => "列表与状态",
      "feedback" => "反馈与加载",
      "containers" => "导航与容器",
      "actions" => "操作与确认",
      "page_actions" => "页面操作",
      "list_examples" => "列表规范"
    }.freeze

    def index
      @groups = GROUPS
      @tab = params[:tab].presence_in(GROUPS.keys) || "media"
      @preview_date = Time.current.in_time_zone("Asia/Shanghai").to_date
      @service_options = ReservationsController::SERVICES
      @clipboard_available = request.ssl? || %w[localhost 127.0.0.1 ::1].include?(request.host)
      @pagination_example, = pagy(Array.new(65), page: 2) if @tab == "records"
      if @tab == "feedback"
        @error_example = Admin.new
        @error_example.errors.add(:base, "请至少保留一个启用的超级管理员。")
      end
      @images = [
        { id: 1, key: "room", asset: "admins/components/room.jpg", title: "门店环境" },
        { id: 2, key: "workspace", asset: "admins/components/workspace.jpg", title: "服务封面" },
        { id: 3, key: "team", asset: "admins/components/team.jpg", title: "团队介绍" }
      ]
      @records = [
        { id: 1, name: "陈女士", mobile: "13800006218", service: "初次咨询", amount: "180.00", status: "待确认", status_key: "pending", color: "orange" },
        { id: 2, name: "李先生", mobile: "13800006291", service: "专业护理", amount: "380.00", status: "已确认", status_key: "confirmed", color: "primary" },
        { id: 3, name: "张女士", mobile: "13800006364", service: "深度体验", amount: "580.00", status: "已完成", status_key: "completed", color: "success" }
      ]
      prepare_list_example if @tab == "list_examples"
    end

    private

    def prepare_list_example
      @list_examples = { "empty" => "空列表", "single" => "单条记录", "logs" => "操作日志筛选", "toolbars" => "页头与工具栏" }
      @list_example = params[:example].presence_in(@list_examples.keys) || "empty"
      return prepare_toolbar_example if @list_example == "toolbars"

      @list_options = @list_example == "logs" ? { operation: AdminsHelper::LOG_ACTIONS } : CustomersController::FILTER_OPTIONS
      @list_filters = @list_options.to_h { |key, options| [ key, params[key].presence_in(options.keys) ] }.compact
      @list_query = params[:q].to_s.strip

      records = case @list_example
      when "single"
        [ @records.first.merge(status: "active", source: "mini_program", period: "today", tag: "new") ]
      when "logs"
        [ { id: 1, name: "示例管理员", operation: "admin.sign_in" } ]
      else
        []
      end
      query = @list_query.downcase
      @list_records = records.select do |record|
        @list_filters.all? { |key, value| record[key] == value } &&
          record.values_at(:id, :name, :mobile).any? { |value| value.to_s.downcase.include?(query) }
      end
    end

    def prepare_toolbar_example
      @toolbar_status_options = ReservationsController::STATUSES.transform_values(&:first)
      @toolbar_status = params[:status].presence_in(@toolbar_status_options.keys)
      @toolbar_query = params[:q].to_s.strip
      @toolbar_range = params[:date_range].to_s.strip
      first_date, last_date = @toolbar_range.scan(/\d{4}-\d{2}-\d{2}/).minmax

      @toolbar_records = @records.each_with_index.filter_map do |record, index|
        date = (@preview_date + index).iso8601
        next if @toolbar_status && @toolbar_status != record[:status_key]
        next if first_date && !date.between?(first_date, last_date)
        next unless record.values_at(:name, :mobile).any? { |value| value.include?(@toolbar_query) }

        record.merge(date: date)
      end
    end
  end
end
