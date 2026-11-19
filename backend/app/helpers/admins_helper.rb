module AdminsHelper
  LOG_ACTIONS = Log::OPERATION_EVENTS.to_h { |(_category, action), label| [ action, label ] }.freeze

  def system_settings_pages
    return [] unless current_admin&.super_admin?

    [
      [ "存储设置", edit_admins_system_settings_storage_path, "admins/system_settings/storage" ],
      [ "外观设置", edit_admins_system_settings_appearance_path, "admins/system_settings/appearance" ]
    ]
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
    content_tag(:div, record.errors[field].join("，"), class: "invalid-feedback d-block", id: "#{field}-error")
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

  def configuration_source(source)
    case source
    when "系统配置", "加密数据库" then [ source, "success" ]
    when "环境变量" then [ "ENV", "success" ]
    when "Rails credentials" then [ "credentials", "success" ]
    when "默认本地" then [ "默认", "secondary" ]
    when "按地域生成" then [ source, "secondary" ]
    when "系统配置（解密失败）" then [ "解密失败", "danger" ]
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
