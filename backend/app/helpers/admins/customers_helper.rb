module Admins::CustomersHelper
  WECHAT_ENTRY_SCENES = {
    1001 => "发现页最近使用", 1005 => "微信首页搜索", 1006 => "发现页搜索", 1007 => "单聊分享", 1008 => "群聊分享",
    1011 => "扫描二维码", 1012 => "长按二维码", 1013 => "相册识别二维码", 1035 => "公众号菜单", 1037 => "小程序跳转",
    1047 => "扫描小程序码", 1048 => "长按小程序码", 1049 => "相册识别小程序码", 1058 => "公众号文章",
    1089 => "聊天下拉最近使用", 1104 => "聊天下拉我的小程序", 1106 => "聊天下拉搜索"
  }.freeze

  def customer_app_filter_options(apps)
    counts = apps.map(&:display_name).tally
    apps.to_h do |app|
      name = app.display_name
      name = "#{name} · #{app.platform_label} · #{app.appid}" if counts[name] > 1
      [ app.id, name ]
    end
  end

  def customer_entry_scene(identity, with_code: false)
    code = identity.first_entry["launch_scene"]
    return if code.blank?

    label = WECHAT_ENTRY_SCENES[code.to_i] if identity.provider == "wechat"
    return code.to_s if label.nil?
    with_code ? "#{label}（#{code}）" : label
  end

  def customer_entry_sources(identities)
    programs = identities.select { |identity| identity.app_type == "mini_program" }
    programs.filter_map do |identity|
      source = [ customer_entry_scene(identity), identity.first_entry["channel_scene"] ].compact_blank.join(" · ")
      next if source.empty?
      programs.many? ? "#{identity.app_name.presence || identity.appid} · #{source}" : source
    end.join("、").presence
  end

  def customer_region(region, include_country: false)
    return unless region.is_a?(Hash)
    places = region.values_at("province", "city").compact_blank
    places.unshift(region["country"]) if include_country || places.empty?
    places.compact_blank.uniq.join(" · ").presence
  end

  def customer_status_badge(status)
    color = status == "active" ? "success" : "secondary"
    tag.span(Admins::CustomersController::STATUSES.fetch(status), class: "badge bg-#{color}-lt")
  end
end
