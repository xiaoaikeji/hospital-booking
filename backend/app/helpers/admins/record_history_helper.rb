module Admins::RecordHistoryHelper
  APPOINTMENT_EVENTS = {
    "appointment.create" => "创建预约", "appointment.checkout" => "发起微信支付",
    "appointment.payment_confirmed" => "确认微信收款", "appointment.payment_close_requested" => "申请取消待支付预约",
    "appointment.payment_closed" => "预约已关单", "appointment.hospital_refund" => "医院办理退款",
    "appointment.refund_request" => "申请退号", "appointment.refund_review" => "审核退号或退差价",
    "appointment.refund_submit" => "提交微信退款", "appointment.refund_result" => "收到退款结果",
    "appointment.refund_pending" => "退款待核实", "appointment.return_completed" => "已办理退号",
    "appointment.refund_sync" => "核对微信退款", "appointment.complete" => "登记已就诊"
  }.freeze
  PATIENT_EVENTS = { "patient.create" => "新增常用就诊人", "patient.update" => "修改常用就诊人", "patient.remove" => "移除常用就诊人" }.freeze
  SYSTEM_SOURCES = { "admin" => "管理员", "user" => "患者", "job" => "后台任务", "scheduler" => "调度",
    "webhook" => "渠道回调", "api" => "接口", "system" => "系统", "console" => "控制台" }.freeze

  def appointment_event_summary(log)
    data = log.details.is_a?(Hash) ? log.details : {}
    case log.action
    when "appointment.hospital_refund"
      { "cancel" => "医院主动退号", "admin_refund" => "医院退差价" }[data["kind"]]
    when "appointment.refund_review"
      { "approve" => "审核同意", "reject" => "审核拒绝" }[data["decision"]]
    when "appointment.refund_result"
      { "SUCCESS" => "微信退款成功", "CLOSED" => "微信退款已关闭", "ABNORMAL" => "微信退款异常", "PROCESSING" => "微信退款处理中" }[data["channel_outcome"]]
    when "appointment.payment_close_requested"
      "付款超时，申请关单" if data["reason"] == "expired"
    end || APPOINTMENT_EVENTS.fetch(log.action)
  end

  def operation_log_title(log)
    if log.action.in?(%w[appointment.hospital_refund appointment.refund_review])
      appointment_event_summary(log)
    else
      log_action_name(log.action)
    end
  end

  def appointment_event_actor(log)
    return "系统确认" if log.action.in?(%w[appointment.payment_confirmed appointment.refund_result appointment.payment_closed appointment.refund_submit appointment.refund_pending appointment.return_completed])
    return "系统" if log.details.is_a?(Hash) && log.details["reason"] == "expired"
    return "医院工作人员" if log.actor_type == "Admin"
    return "患者" if log.actor_type == "User"

    "系统"
  end

  def system_record_summary(log)
    reason = log.details["reason"] if log.details.is_a?(Hash)
    case log.action
    when "wechat_pay.gateway_error"
      Wechat::PaymentV3Client.diagnostic_details(log.details)[:reason] || "微信支付网关异常（历史详情已隐藏）"
    when "appointment.create"
      { "payment_unavailable" => "微信支付暂不可用", "write_failed" => "预约写入失败" }
        .fetch(reason) { Appointments::Create::MESSAGES.stringify_keys.fetch(reason, "预约创建失败") }
    when "admin.create" then "控制台初始化管理员"
    end
  end

  def record_target_link(log)
    label = "查看业务记录"
    if log.target_type == "Appointment"
      order = Appointment.readable_by_admin(current_admin).find_by(id: log.target_id)
      return unless order

      refund_id = log.details["refund_record_id"] if log.details.is_a?(Hash)
      item = order.readable_refund_items.find { |row| row["id"] == refund_id } if refund_id
      if item
        label = item["kind"] == "cancel" && item["amount_cents"] == 0 ? "查看退号记录" : "查看退款记录"
      end
      path = admins_reservation_path(order.order_no, anchor: ("refund-#{refund_id}" if item))
    else
      path = record_target_path(log)
    end
    link_to label, path, class: "btn btn-sm btn-info mt-3" if path
  end

  def record_target_path(log)
    id = log.target_id
    case log.target_type
    when "Doctor" then admins_doctor_path(id) if Doctor.current.exists?(id)
    when "Department" then admins_department_path(id) if Department.exists?(id)
    when "Schedule"
      doctor = log.details["doctor_id"] if log.details.is_a?(Hash)
      admins_doctor_schedule_path(doctor) if doctor.is_a?(Integer) && Doctor.current.exists?(doctor)
    when "Notification" then admins_notification_path(id) if current_admin.super_admin? && Notification.exists?(id)
    when "HospitalNoticeTemplate" then edit_admins_hospital_notice_path(id) if current_admin.super_admin? && HospitalNoticeTemplate.exists?(id)
    when "App" then admins_app_path(id) if current_admin.super_admin? && App.exists?(id)
    when "Setting"
      return unless current_admin.super_admin? && Setting.exists?(id)
      case log.action
      when "storage_settings.update", "storage_settings.refresh" then edit_admins_system_settings_storage_path
      when "appearance.update" then edit_admins_system_settings_appearance_path
      when "hospital.update" then edit_admins_system_settings_hospital_path
      when "appointment.phone_policy", "appointment.night_shift", "appointment.update" then edit_admins_system_settings_appointment_path
      when "wechat_pay.update" then edit_admins_system_settings_wechat_pay_path
      when "map_settings.update" then edit_admins_system_settings_map_path
      when "wechat.notification_settings" then edit_admins_system_settings_wecom_notifications_path
      when "app.user_sharing" then edit_admins_user_sharing_path
      end
    when "Admin"
      return if log.action == "personal_appearance.update"
      return edit_admins_account_path if log.action == "admin.password" && id == current_admin.id
      edit_admins_administrator_path(id) if current_admin.super_admin? && Admin.exists?(id)
    when "Link" then edit_admins_page_link_path(id) if current_admin.super_admin? && Link.exists?(id)
    when "Poster" then edit_admins_poster_path(id) if current_admin.super_admin? && Poster.exists?(id)
    end
  end
end
