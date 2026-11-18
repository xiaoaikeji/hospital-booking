module AdminsHelper
  LOG_ACTIONS = { "admin.sign_in" => "管理员登录", "admin.sign_out" => "管理员退出", "admin.create" => "新增管理员",
    "admin.update" => "修改管理员", "admin.password" => "修改本人密码", "storage_settings.update" => "修改存储配置" }.freeze

  def admin_field_class(record, field, base = "form-control")
    class_names(base, "is-invalid" => record.errors[field].any?)
  end

  def admin_field_errors(record, field)
    return if record.errors[field].empty?
    content_tag(:div, record.errors[field].join("，"), class: "invalid-feedback d-block", id: "#{field}-error")
  end

  def log_action_name(action) = LOG_ACTIONS.fetch(action, action)

  def configuration_source(source)
    case source
    when "系统配置" then [ "系统配置", "success" ]
    when "环境变量" then [ "ENV", "success" ]
    when "Rails credentials" then [ "credentials", "success" ]
    when "默认本地" then [ "默认", "secondary" ]
    when "系统配置（解密失败）" then [ "解密失败", "danger" ]
    else [ "未配置", "danger" ]
    end
  end

  def configuration_placeholder(source, example:, fallback_value: nil)
    label, color = configuration_source(source)
    return "#{fallback_value}（#{label}），留空保留" if fallback_value.present?
    return "已配置（#{label}），留空保留" if color == "success"
    return "解密失败，请重新填写或清除" if label == "解密失败"
    example
  end
end
