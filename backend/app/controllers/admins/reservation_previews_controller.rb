module Admins
  class ReservationPreviewsController < BaseController
    before_action :prepare_preview, only: [ :index, :show, :edit ]
    before_action :set_preview_reservation, only: [ :show, :edit ]

    STATUSES = {
      "pending" => [ "待确认", "orange" ],
      "confirmed" => [ "已确认", "blue" ],
      "in_progress" => [ "服务中", "cyan" ],
      "completed" => [ "已完成", "green" ],
      "cancelled" => [ "已取消", "secondary" ]
    }.freeze
    SERVICES = [ "初次咨询", "专业护理", "深度体验" ].freeze
    STAFF = [ "林顾问", "王老师", "赵老师" ].freeze
    SOURCES = [ "小程序", "电话预约", "门店扫码", "后台录入" ].freeze
    PERIODS = { "today" => "今日", "tomorrow" => "明日", "week" => "近7天" }.freeze

    def index
      @status_options = STATUSES.transform_values(&:first)
      @period_options = PERIODS
      @filters = {
        status: params[:status].presence_in(STATUSES.keys),
        service: params[:service].presence_in(SERVICES),
        period: params[:period].presence_in(PERIODS.keys)
      }.compact
      @query = params[:q].to_s.strip

      records = preview_reservations.select do |reservation|
        matches_status = @filters[:status].nil? || reservation[:status] == @filters[:status]
        matches_service = @filters[:service].nil? || reservation[:service] == @filters[:service]
        date = reservation[:starts_at].to_date
        matches_period = case @filters[:period]
        when "today" then date == @preview_date
        when "tomorrow" then date == @preview_date + 1
        when "week" then date.between?(@preview_date - 6, @preview_date)
        else true
        end
        matches_query = @query.blank? || [ reservation[:number], reservation[:customer], reservation[:mobile] ].any? { |value| value.downcase.include?(@query.downcase) }
        matches_status && matches_service && matches_period && matches_query
      end

      @pagy, @reservations = pagy(records)
      @pagy, @reservations = pagy(records, page: @pagy.last) if @pagy.page > @pagy.last
      @total_count = @pagy.count
      @total_pages = @pagy.pages
      @page = @pagy.page
      @first_record = @pagy.from
      @last_record = @pagy.to
    end

    def show
      @created_at = @reservation[:starts_at] - 1.day
      @paid_at = @reservation[:status] == "pending" ? nil : @created_at + 5.minutes
      @history = preview_history(@reservation)
      if @reservation[:status] == "cancelled"
        @progress_steps = [ "已创建", "已取消" ]
        @current_step = 1
      else
        @progress_steps = [ "已创建", "已确认", "服务中", "已完成" ]
        @current_step = %w[pending confirmed in_progress completed].index(@reservation[:status])
      end
      @primary_action = {
        "pending" => { label: "确认预约", title: "确认这条预约", description: "请核对客户、预约时间和服务人员后确认。" },
        "confirmed" => { label: "开始服务", title: "确认开始服务", description: "请确认客户已到店，并已准备好提供服务。" },
        "in_progress" => { label: "完成服务", title: "确认完成服务", description: "请确认本次预约的服务项目已全部完成。" }
      }[@reservation[:status]]
    end

    def edit
    end

    private

    def prepare_preview
      @preview_date = Time.current.in_time_zone("Asia/Shanghai").to_date
      @service_options = SERVICES
      @staff_options = STAFF
      @source_options = SOURCES
    end

    def set_preview_reservation
      @reservation = preview_reservations.find { |reservation| reservation[:id].to_s == params[:id] }
      return head(:not_found) unless @reservation

      @list_context = params.permit(:q, :status, :service, :period, :page).to_h
    end

    def preview_history(reservation)
      events = [ { title: "创建预约", time: @created_at, description: "通过#{reservation[:source]}创建预约，选择#{reservation[:service]}。", operator: "客户" } ]
      unless reservation[:status] == "pending"
        events << { title: "确认预约", time: @created_at + 15.minutes, description: "已核对预约时间，并安排#{reservation[:staff]}提供服务。", operator: "管理员" }
      end
      if %w[in_progress completed].include?(reservation[:status])
        events << { title: "开始服务", time: reservation[:starts_at], description: "客户已到店，#{reservation[:service]}开始。", operator: reservation[:staff] }
      end
      if reservation[:status] == "completed"
        events << { title: "完成服务", time: reservation[:ends_at], description: "本次服务已结束，预约标记为已完成。", operator: reservation[:staff] }
      elsif reservation[:status] == "cancelled"
        events << { title: "取消预约", time: @created_at + 30.minutes, description: "预约已取消，示例支付状态为已退款。", operator: "管理员" }
      end
      events
    end

    # Read-only sample records for the UI preview; no database or booking mutations.
    def preview_reservations
      customers = %w[陈女士 李先生 张女士 周先生 刘女士 王先生 赵女士 孙先生 林女士 郑先生 黄女士 吴先生 何女士 高先生 罗女士 许先生 梁女士 宋先生 唐女士 韩先生 冯女士 邓先生 曹女士 彭先生]
      offsets = [ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 2, 2, -1, -1, -1, -2, -2, -3, -4, -5 ]
      today_statuses = %w[pending confirmed confirmed in_progress completed cancelled pending completed]

      customers.each_with_index.map do |customer, index|
        service_index = index % SERVICES.size
        duration = [ 30, 60, 90 ][service_index]
        date = @preview_date + offsets[index]
        starts_at = Time.find_zone!("Asia/Shanghai").local(date.year, date.month, date.day, 9 + index % 8, index.even? ? 0 : 30)
        status = if offsets[index].zero?
          today_statuses[index]
        elsif offsets[index].positive?
          index.even? ? "pending" : "confirmed"
        else
          index % 5 == 0 ? "cancelled" : "completed"
        end
        payment = status == "cancelled" ? [ "已退款", "secondary" ] : (status == "pending" ? [ "待支付", "orange" ] : [ "已支付", "green" ])

        {
          id: index + 1,
          number: "BK#{date.strftime('%Y%m%d')}#{format('%04d', index + 1)}",
          customer: customer,
          mobile: "1380000#{6218 + index * 73}",
          service: SERVICES[service_index],
          duration: duration,
          staff: STAFF[service_index],
          starts_at: starts_at,
          ends_at: starts_at + duration.minutes,
          amount: [ "180.00", "380.00", "580.00" ][service_index],
          source: SOURCES[index % SOURCES.size],
          status: status,
          status_label: STATUSES.fetch(status).first,
          status_color: STATUSES.fetch(status).last,
          payment_label: payment.first,
          payment_color: payment.last,
          note: [ "首次到店，请提前联系确认。", "希望安排靠窗的位置。", "已告知客户提前 10 分钟到店。", "无特殊备注。" ][index % 4]
        }
      end
    end
  end
end
