module Appointments
  class GroupNotice
    EVENTS = {
      "appointment_confirmed" => "预约成功", "return_requested" => "退号待审核",
      "appointment_returned" => "退号已办理", "unpaid_cancelled" => "患者取消待支付预约",
      "refund_attention" => "退款失败需处理"
    }.freeze

    COMMON = {
      event_name: ["事件名称", "预约成功"], occurred_at: ["发生时间", "2030-05-06 09:15:00"],
      order_no: ["预约号", "20300506091500000001"], status: ["预约状态", "待就诊"],
      created_at: ["下单时间", "2030-05-06 09:00:00"], platform: ["来源平台", "微信小程序"],
      hospital: ["医院名称", "示例医院"], address: ["就诊地址", "示例路一号"],
      department: ["科室", "内科"], doctor: ["医生", "示例医生"], visit_date: ["就诊日期", "2030-05-07"],
      weekday: ["星期", "星期二"], shift: ["班次", "上午"], mode: ["预约方式", "分时"],
      slot: ["预约时段", "09:00–09:30"], starts_at: ["分时开始", "09:00"], ends_at: ["分时结束", "09:30"],
      patient: ["就诊人称呼", "林＊"], gender: ["性别", "女"], age: ["年龄", "32"],
      phone_tail: ["本单联系电话尾号", "0123"], fee: ["挂号费", "20元"], payable: ["订单应付", "20元"],
      discount: ["已记录订单优惠", "0元"], paid: ["现金实付", "15元"], payment_status: ["支付状态", "已支付"],
      payment_no: ["业务支付单号", "20300506090000000002"], paid_at: ["支付时间", "2030-05-06 09:15:00"],
      expires_at: ["付款截止时间", "2030-05-06 09:30:00"]
    }.freeze
    REFUND = {
      refund_no: ["退款单号", "20300506092000000003"], kind: ["申请类型", "退号"],
      initiator: ["申请来源", "患者申请"], reason: ["办理原因", "行程调整"], requested_at: ["申请时间", "2030-05-06 09:20:00"],
      requested: ["本次申请退款金额", "20元"], refunded: ["本次已确认现金实退", "0元"],
      total_refunded: ["累计现金实退", "0元"], available: ["剩余可退金额", "0元"]
    }.freeze
    HANDLED = { handled_at: ["审核或办理时间", "2030-05-06 09:25:00"] }.freeze
    CANCELLED = { cancelled_at: ["取消时间", "2030-05-06 09:25:00"] }.freeze
    RESULTS = {
      "return_requested" => "等待医院审核", "appointment_returned" => "预约已取消",
      "unpaid_cancelled" => "未付款，预约已关单", "refund_attention" => "退款需人工处理"
    }.freeze

    def self.register
      EVENTS.each do |event, label|
        spec = COMMON.merge(event_name: ["事件名称", label])
        spec.merge!(REFUND) if %w[return_requested appointment_returned refund_attention].include?(event)
        spec.merge!(HANDLED) if %w[appointment_returned refund_attention].include?(event)
        spec.merge!(CANCELLED) if %w[appointment_returned unpaid_cancelled refund_attention].include?(event)
        spec[:result] = ["办理结果", RESULTS[event]] if RESULTS.key?(event)
        spec[:failure_reason] = ["失败原因", "微信已关闭本次退款"] if event == "refund_attention"
        if event == "unpaid_cancelled"
          spec.delete(:paid_at)
          spec.merge!(REFUND.slice(:initiator, :requested_at))
          spec.merge!(paid: ["现金实付", "0元"], payment_status: ["支付状态", "已关单"])
        end
        status = { "appointment_returned" => "已取消", "unpaid_cancelled" => "已取消", "return_requested" => "退号审核中" }[event]
        spec[:status] = ["预约状态", status] if status
        fields = spec.transform_values { |name, example| { label: name, example: example, optional: true } }
        Notifications::EventCatalog.register(event, label: label, fields: fields, template_message: false)
      end
    end

    def self.setting_key(event) = "hospital_notice.#{event}"

    def self.configured_key
      key = Notifications::WecomSettings.new.key
      key if key.is_a?(String) && key.match?(/\A[A-Za-z0-9-]{8,64}\z/)
    end

    def self.deliverable?(event)
      Setting.find_by(key: setting_key(event))&.settings&.fetch("enabled", false) && configured_key.present?
    end

    # The business transition holds the appointment lock. Persist the snapshot in
    # that transaction; Notification enqueues only after the outer commit.
    def self.publish(event, order, item = nil)
      template = Setting.find_by(key: setting_key(event))&.settings
      return unless template && template["enabled"]

      key = configured_key
      return unless key

      Notification.transaction(requires_new: true) do
        Notifications.dispatch(event: event, subject: order, messages: template.fetch("messages"),
          target: Notifications::Channels::WecomGroup.target(key), data: new(event, order, item).values,
          idempotency_key: item&.fetch("refund_no") || order.order_no)
      end
    rescue Notifications::Error, IntegrationSettings::ConfigurationError, ActiveRecord::Encryption::Errors::Base
      Rails.logger.warn("医院通知配置不可用 event=#{event} appointment_id=#{order.id}")
    end

    def initialize(event, order, item)
      @event, @order, @item = event, order, item
    end

    def values
      o = @order
      base = {
        event_name: EVENTS.fetch(@event), occurred_at: Time.current, order_no: o.order_no, status: o.status_label,
        created_at: o.created_at, platform: "#{App::PROVIDERS[o.source_platform]}小程序",
        hospital: o.hospital_snapshot["company_name"], address: o.hospital_snapshot["address"],
        department: o.department_name, doctor: o.doctor_name, visit_date: o.appointment_date.to_s,
        weekday: "星期#{'日一二三四五六'[o.appointment_date.wday]}", shift: ScheduleCalendar::SHIFT_LABELS[o.time_slot],
        mode: o.booking_start_at ? "分时" : "整班", slot: o.slot_label,
        starts_at: o.booking_start_at&.strftime("%H:%M"), ends_at: o.booking_end_at&.strftime("%H:%M"),
        patient: o.patient_name.presence && "#{o.patient_name.first}＊", gender: o.patient_sex,
        age: o.patient_age, phone_tail: o.patient_mobile.presence&.last(4),
        fee: money(o.fee_cents), payable: money(o.payable_amount_cents), discount: money(o.discount_cents),
        paid: money(o.paid_amount_cents), payment_status: Appointment::PAYMENT_LABELS[o.payment_status],
        payment_no: o.payment_no, paid_at: o.paid_at, expires_at: o.payment_expires_at,
        initiator: "患者申请", requested_at: o.payment_cancel_requested_at,
        cancelled_at: o.cancelled_at, result: RESULTS[@event]
      }
      @item ? base.merge(refund_values) : base
    end

    private

    def money(cents) = cents.nil? ? "待核对" : "#{Appointment.cents_in_yuan(cents)}元"

    def refund_values
      item = @item
      total = money(@order.refunded_amount_cents)
      if @order.refunded_amount_cents.nil? && (known = @order.confirmed_refunded_cash_cents)
        total = "已确认#{money(known)}，其余待核对"
      end
      {
        refund_no: item["refund_no"], kind: item["kind"] == "cancel" ? "退号" : "退差价",
        initiator: item["requested_by_type"] == "Admin" ? "医院办理" : "患者申请",
        reason: item["reason"], requested_at: Time.zone.parse(item.fetch("created_at")),
        handled_at: Time.zone.parse(item.fetch("updated_at")), requested: money(item["amount_cents"]),
        refunded: money(item.fetch("payer_refund_cents", 0)),
        total_refunded: total, available: money(@order.available_refund_cents),
        failure_reason: "微信已关闭本次退款"
      }
    end
  end
end
