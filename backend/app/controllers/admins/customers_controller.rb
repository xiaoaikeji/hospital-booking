module Admins
  class CustomersController < BaseController
    FILTER_OPTIONS = {
      status: { "active" => "正常", "disabled" => "已停用" },
      source: { "mini_program" => "小程序", "phone" => "电话登记", "store" => "门店登记", "import" => "批量导入" },
      period: { "today" => "今日", "week" => "近7天", "month" => "近30天" },
      tag: { "new" => "新客户", "returning" => "回头客", "vip" => "VIP客户" }
    }.freeze

    def index
      @filter_options = FILTER_OPTIONS
      @filters = FILTER_OPTIONS.each_with_object({}) do |(key, options), filters|
        value = params[key].presence_in(options.keys)
        filters[key] = value if value
      end
      @query = params[:q].to_s.strip
      @advanced_filters = @filters.slice(:period, :tag).any?
      @customers = [].freeze
    end
  end
end
