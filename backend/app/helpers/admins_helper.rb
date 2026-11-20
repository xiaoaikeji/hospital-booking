module AdminsHelper
  LOG_ACTIONS = Log::OPERATION_EVENTS.to_h { |(_category, action), label| [ action, label ] }.freeze

  def system_settings_pages
    return [] unless current_admin&.super_admin?

    [
      [ "存储设置", edit_admins_system_settings_storage_path, "admins/system_settings/storage" ],
      [ "外观设置", edit_admins_system_settings_appearance_path, "admins/system_settings/appearance" ],
      [ "微信通知设置", edit_admins_system_settings_wechat_notifications_path, "admins/system_settings/wechat_notifications" ]
    ]
  end

  def management_navigation_groups
    groups = []
    admin_pages = []
    if current_admin.super_admin?
      groups << [ "应用管理", :device_mobile, [
        [ "应用列表", admins_apps_path, %w[admins/apps admins/app_privacy_settings] ],
        [ "代码发布", admins_mini_program_releases_path, %w[admins/mini_program_releases admins/wechat_releases] ],
        [ "代码模板", admins_code_templates_path, "admins/code_templates" ],
        [ "插件列表", admins_plugins_path, "admins/plugins" ],
        [ "违规记录", admins_illegal_records_path, "admins/illegal_records" ],
        [ "微信第三方平台", admins_wechat_platform_path, "admins/wechat_platforms" ],
        [ "开放平台账号", admins_open_platform_accounts_path, "admins/open_platform_accounts" ]
      ] ]
      groups << [ "运营工具", :templates, [
        [ "公众号关联管理", admins_official_account_links_path, "admins/official_account_links" ],
        [ "公众号粉丝", admins_official_account_fans_path, "admins/official_account_fans" ],
        [ "公众号自定义菜单", admins_official_account_menus_path, "admins/official_account_menus" ],
        [ "渠道二维码", admins_channel_qrcodes_path, "admins/channel_qrcodes" ],
        [ "通用海报", admins_posters_path, "admins/posters" ]
      ] ]
      groups << [ "通知管理", :bell, [
        [ "回复内容", admins_reply_contents_path, %w[admins/reply_contents admins/reply_rules] ],
        [ "微信模板消息", admins_template_messages_path, "admins/template_messages" ],
        [ "企微通知文案", edit_admins_wecom_notification_content_path, "admins/wecom_notification_contents" ],
        [ "发送记录", admins_notifications_path, %w[admins/notifications admins/wechat_notifications] ]
      ] ]
      admin_pages << [ "管理员", admins_administrators_path, "admins/administrators" ]
      admin_pages << [ "后台任务", admins_background_jobs_path, "admins/background_jobs" ]
    end
    admin_pages << [ "操作日志", admins_operation_logs_path, "admins/operation_logs" ]
    admin_pages << [ "组件规范", admins_components_path, "admins/components" ]
    groups << [ "后台管理", :settings, admin_pages ]
  end

  def wechat_component_messages_template_url
    api_wechat_component_messages_url(appid: "APPID").sub("/APPID/", '/$APPID$/')
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
    [ type.presence, ("##{id}" if id) ].compact.join(" ").presence || "—"
  end

  def app_status_badge(status)
    color = { "active" => "success", "auditing" => "warning", "disabled" => "secondary" }.fetch(status)
    tag.span(App::STATUSES.fetch(status), class: "badge bg-#{color}-lt")
  end

  def notification_event_label(event)
    Notifications::EventCatalog.definitions.dig(event, "label") || {
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
    when "默认本地" then [ "默认", "secondary" ]
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
