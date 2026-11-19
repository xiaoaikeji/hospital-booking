class Log < ApplicationRecord
  OPERATION_EVENTS = {
    [ "wechat", "wechat.authorize" ] => "发起平台授权",
    [ "wechat", "wechat.authorized" ] => "完成平台授权",
    [ "wechat", "wechat.link_create" ] => "发起小程序关联",
    [ "wechat", "wechat.link_delete" ] => "解除小程序关联",
    [ "wechat", "wechat.link_verify" ] => "核实小程序关联",
    [ "wechat", "wechat.open_platform_create" ] => "创建开放平台账号",
    [ "wechat", "wechat.open_platform_bind" ] => "绑定开放平台账号",
    [ "wechat", "wechat.open_platform_unbind" ] => "解绑开放平台账号",
    [ "wechat", "wechat.open_platform_sync" ] => "同步开放平台绑定",
    [ "wechat", "wechat.qrcode_refresh" ] => "刷新小程序码缓存",
    [ "wechat", "wechat.tester_bind" ] => "绑定体验者",
    [ "wechat", "wechat.tester_unbind" ] => "解绑体验者",
    [ "wechat", "wechat.privacy_update" ] => "更新开发版隐私指引",
    [ "wechat", "wechat.category_add" ] => "申请服务类目",
    [ "wechat", "wechat.category_delete" ] => "删除服务类目",
    [ "wechat", "wechat.category_verify" ] => "核实服务类目操作",
    [ "wechat", "wechat.server_domains" ] => "修改服务器域名",
    [ "wechat", "wechat.business_domains" ] => "修改业务域名",
    [ "wechat", "wechat.template_add" ] => "草稿加入模板库",
    [ "wechat", "wechat.template_delete" ] => "删除微信模板",
    [ "wechat", "wechat.publication_mode" ] => "修改本轮发布方式",
    [ "wechat", "wechat.upload" ] => "上传体验版",
    [ "wechat", "wechat.submit" ] => "提交微信审核",
    [ "wechat", "wechat.sync" ] => "核对微信结果",
    [ "wechat", "wechat.withdraw" ] => "撤回微信审核",
    [ "wechat", "wechat.resume_auto" ] => "补排自动发布任务",
    [ "wechat", "wechat.publish" ] => "发布微信版本",
    [ "wechat", "wechat.close" ] => "关闭发布记录",
    [ "wechat", "wechat.delete" ] => "删除发布记录",
    [ "wechat", "wechat.resolve" ] => "核实微信结果",
    [ "app", "app.create" ] => "新增应用",
    [ "app", "app.update" ] => "修改应用资料、密钥或状态",
    [ "app", "app.destroy" ] => "删除应用",
    [ "security", "admin.sign_in" ] => "管理员登录",
    [ "security", "admin.sign_out" ] => "管理员退出",
    [ "security", "admin.create" ] => "新增管理员",
    [ "security", "admin.update" ] => "修改管理员",
    [ "security", "admin.password" ] => "修改本人密码",
    [ "security", "storage_settings.update" ] => "修改存储配置",
    [ "security", "storage_settings.refresh" ] => "刷新存储客户端",
    [ "settings", "appearance.update" ] => "修改默认外观",
    [ "settings", "personal_appearance.update" ] => "修改个人外观"
  }.freeze

  def self.operations_visible_to(admin)
    operations = where(source: "admin", [ :category, :action ] => OPERATION_EVENTS.keys)
    return operations if admin.super_admin?

    operations.where(actor_type: admin.class.name, actor_id: admin.id)
  end

  validates :source, :category, :action, :status, presence: true
  def readonly? = persisted?

  # 只传变更字段名和安全结果，不接收请求参数或密钥原值。
  def self.record!(action:, category:, actor: nil, target: nil, details: {}, request: nil, source: "admin", status: "success")
    safe_details = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(details)
    create!(source: source, category: category, action: action, status: status,
      actor_type: actor&.class&.name, actor_id: actor&.id, target_type: target&.class&.name, target_id: target&.id,
      details: safe_details, request_id: request&.request_id, correlation_id: request&.request_id,
      ip_address: request&.remote_ip, user_agent: request&.user_agent&.truncate(2000))
  end
end
