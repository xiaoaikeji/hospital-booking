module AdminsHelper
  LOG_ACTIONS = Log::OPERATION_EVENTS.to_h { |(_category, action), label| [ action, label ] }.freeze

  def system_settings_pages
    return [] unless current_admin&.super_admin?

    [
      [ "存储设置", edit_admins_system_settings_storage_path, "admins/system_settings/storage" ],
      [ "医院资料", edit_admins_system_settings_hospital_path, "admins/system_settings/hospital" ],
      [ "预约设置", edit_admins_system_settings_appointment_path, "admins/system_settings/appointment" ],
      [ "微信支付", edit_admins_system_settings_wechat_pay_path, "admins/system_settings/wechat_pay" ],
      [ "地图服务", edit_admins_system_settings_map_path, "admins/system_settings/map" ],
      [ "外观设置", edit_admins_system_settings_appearance_path, "admins/system_settings/appearance" ],
      [ "企微通知设置", edit_admins_system_settings_wecom_notifications_path, "admins/system_settings/wecom_notifications" ]
    ]
  end

  def management_navigation_groups
    groups = [ [ "基础资料", :package, [
      [ "科室管理", admins_departments_path, "admins/departments" ],
      [ "医生资料", admins_doctors_path, %w[admins/doctors admins/doctor_schedules] ]
    ] ] ]
    admin_pages = []
    if current_admin.super_admin?
      groups << [ "应用管理", :device_mobile, [
        [ "应用列表", admins_apps_path, "admins/apps" ],
        [ "小程序用户共享", edit_admins_user_sharing_path, "admins/user_sharing" ],
        [ "小程序页面配置", admins_page_links_path, "admins/page_links" ],
        [ "插件列表", admins_plugins_path, "admins/plugins" ]
      ] ]
      groups << [ "运营工具", :templates, [
        [ "公众号粉丝", admins_official_account_fans_path, "admins/official_account_fans" ],
        [ "公众号自定义菜单", admins_official_account_menus_path, "admins/official_account_menus" ],
        [ "渠道二维码", admins_channel_qrcodes_path, "admins/channel_qrcodes" ],
        [ "通用海报", admins_posters_path, "admins/posters" ]
      ] ]
      groups << [ "通知管理", :bell, [
        [ "通知列表", admins_hospital_notices_path, "admins/hospital_notices" ],
        [ "通知记录", admins_notifications_path, %w[admins/notifications admins/wechat_notifications] ]
      ] ]
      admin_pages << [ "管理员", admins_administrators_path, "admins/administrators" ]
      admin_pages << [ "系统记录", admins_system_logs_path, "admins/system_logs" ]
      admin_pages << [ "后台任务", admins_background_jobs_path, "admins/background_jobs" ]
    end
    admin_pages << [ "操作日志", admins_operation_logs_path, "admins/operation_logs" ]
    admin_pages << [ "组件规范", admins_components_path, "admins/components" ]
    groups << [ "后台管理", :settings, admin_pages ]
  end

  def admin_appearance
    @admin_appearance ||= AppearanceSettings.new(admin: current_admin)
  end

  def admin_theme_attributes
    admin_appearance.values.filter_map do |key, value|
      [ "data-bs-#{key.dasherize}", value ] unless value == AppearanceSettings::TABLER_DEFAULTS.fetch(key)
    end.to_h
  end

  def admin_field_class(record, field, base = "form-control")
    class_names(base, "is-invalid" => record.errors[field].any?)
  end

  def admin_field_errors(record, field)
    return if record.errors[field].empty?
    admin_field_error(record.errors[field].join("，"), id: "#{field}-error")
  end

  def admin_field_error(message, id:)
    tag.div(message, class: "invalid-feedback d-block", id: id) if message
  end

  def log_action_name(action) = LOG_ACTIONS.fetch(action, action)

  def admin_list_time(time, fallback: "—")
    time ? l(time, format: "%Y-%m-%d %H:%M") : fallback
  end

  def log_subject_label(type, id)
    type = { "Department" => "科室", "Doctor" => "医生", "HospitalNoticeTemplate" => "通知模板", "Notification" => "通知记录",
      "Appointment" => "预约", "Admin" => "管理员", "User" => "患者账号", "App" => "应用", "Schedule" => "排班",
      "Poster" => "海报", "Link" => "页面配置", "Setting" => "配置" }.fetch(type, nil)
    [ type.presence, ("##{id}" if id) ].compact.join(" ").presence || "—"
  end

  def app_status_badge(status)
    color = { "active" => "success", "auditing" => "warning", "disabled" => "secondary" }.fetch(status)
    tag.span(App::STATUSES.fetch(status), class: "badge bg-#{color}-lt")
  end

  def directory_status_badge(entry)
    color = entry.enabled? ? "success" : "secondary"
    tag.span(DirectoryEntry::STATUSES.fetch(entry.status), class: "badge bg-#{color}-lt")
  end

  def interval_skip_reasons(log)
    replies = log.details["replies"] if log.details.is_a?(Hash)
    return ["已跳过回复"] unless replies.is_a?(Array) && replies.any?
    replies.map do |reply|
      reason = reply["reason"] if reply.is_a?(Hash)
      next reason if reason == "本次互动已匹配同一回复组"
      minutes = reason.to_s[/\A同一粉丝在 ([1-9]\d{0,4}) 分钟发送间隔内已触发此回复\z/, 1]
      minutes && minutes.to_i <= Notifications::SendInterval::MAX_MINUTES ? "同一粉丝在 #{minutes} 分钟发送间隔内已触发此回复" : "已跳过回复"
    end
  end

  def notification_event_label(event)
    Notifications::EventCatalog.definitions.dig(event, "label") || WechatNotificationEvent::LABELS[event] || {
      "official_account.keyword" => "关键词回复",
      "official_account.subscribe" => "关注回复",
      "official_account.scan" => "扫码回复",
      "official_account.click" => "菜单回复"
    }.fetch(event, "其他事件")
  end

  def notification_status_badge(status, label = Notification::STATES.fetch(status))
    color = { "pending" => "secondary", "sending" => "info", "sent" => "success", "failed" => "danger",
      "unknown" => "warning", "skipped" => "secondary", "partially_skipped" => "secondary" }.fetch(status)
    tag.span(label, class: "badge bg-#{color}-lt")
  end

  def configuration_source(source)
    case source
    when "系统配置", "加密数据库" then [ source, "success" ]
    when "环境变量" then [ "ENV", "success" ]
    when "Rails credentials" then [ "credentials", "success" ]
    when "默认本地", "系统默认" then [ "默认", "secondary" ]
    when "按地域生成" then [ source, "secondary" ]
    when "系统配置（解密失败）" then [ "解密失败", "danger" ]
    when "部署配置无效" then [ source, "danger" ]
    else [ "未配置", "danger" ]
    end
  end

  def configuration_placeholder(source, example:)
    label, color = configuration_source(source)
    return "已配置（#{label}），留空保留" if color == "success"
    return "解密失败，请重新填写或清除" if label == "解密失败"
    example
  end
end
