require "digest"

class AppearanceSettings
  include ActiveModel::Model

  # 每组选项的第一项是项目初始默认值，值与 Tabler 面板一致。
  OPTIONS = {
    "theme" => { "auto" => "跟随系统", "light" => "浅色", "dark" => "深色" },
    "theme_primary" => { "blue" => "蓝色", "azure" => "天蓝", "indigo" => "靛蓝", "purple" => "紫色", "pink" => "粉色",
      "red" => "红色", "orange" => "橙色", "yellow" => "黄色", "lime" => "青柠", "green" => "绿色", "teal" => "蓝绿", "cyan" => "青色", "inverted" => "黑白反色" },
    "theme_font" => { "sans-serif" => "无衬线", "serif" => "衬线", "monospace" => "等宽", "comic" => "手写" },
    "theme_base" => { "neutral" => "中性灰", "slate" => "石板灰", "gray" => "灰色", "zinc" => "锌灰", "stone" => "石灰", "mist" => "雾灰" },
    "theme_radius" => %w[1 0 0.5 1.5 2].index_by(&:itself),
    "layout" => { "fluid" => "全宽", "default" => "标准", "boxed" => "盒式" },
    "navbar_position" => { "combined" => "侧栏 + 顶栏", "horizontal" => "仅顶栏", "vertical" => "仅侧栏" },
    "navbar_theme" => { "default" => "跟随页面", "dark" => "深色", "primary" => "主题色" },
    "navbar" => { "default" => "随页滚动", "sticky" => "吸顶" },
    "navbar_style" => { "default" => "贴边", "floating" => "悬浮" },
    "offcanvas_style" => { "default" => "贴边", "floating" => "悬浮" },
    "sidebar" => { "default" => "展开", "folded" => "折叠", "folded-hover" => "悬停展开" }
  }.freeze
  SCHEME_LABELS = OPTIONS.fetch("theme").merge("dark-nav" => "深色导航", "colored" => "主题色导航").freeze
  LABELS = { "theme" => "配色模式", "theme_primary" => "主题色", "theme_font" => "字体", "theme_base" => "灰阶", "theme_radius" => "圆角",
    "layout" => "页面宽度", "navbar_position" => "导航位置", "navbar_theme" => "导航颜色", "navbar" => "顶栏滚动",
    "navbar_style" => "导航样式", "offcanvas_style" => "抽屉样式", "sidebar" => "侧栏样式" }.freeze
  DEFAULTS = OPTIONS.transform_values { |choices| choices.keys.first }.freeze
  TABLER_DEFAULTS = DEFAULTS.merge("layout" => "default", "navbar_position" => "horizontal").freeze

  def initialize(admin: nil)
    @admin = admin
    @global = Setting.find_by(key: "appearance")
  end

  def defaults = DEFAULTS.merge(@global&.settings || {})
  def overrides = @admin&.appearance_overrides || {}
  def values = defaults.merge(overrides)

  def revision
    Digest::SHA256.hexdigest([ @admin&.id, defaults.sort, overrides.sort ].to_json)
  end

  def save(changes, expected_revision:, actor:, request:, reset: false)
    action = @admin ? "personal_appearance.update" : "appearance.update"
    audit = { action: action, category: "settings", actor: actor, request: request }
    attempted = reset ? overrides : changes
    errors.clear
    return true if persist(changes, expected_revision: expected_revision, reset: reset, audit: audit)

    # 回滚不会还原模型内存中的属性，表单及其版本须使用已保存的值。
    @global = Setting.find_by(key: "appearance")
    @admin&.reload
    Log.record!(**audit, target: @admin || @global, status: "failed",
      details: { fields: attempted.is_a?(Hash) ? attempted.keys & OPTIONS.keys : [], reason: errors[:base].first })
    false
  end

  private

  def persist(changes, expected_revision:, reset:, audit:)
    Setting.transaction(requires_new: true) do
      # 同一把行锁保护默认值和基于它计算的个人差量，包括首次保存。
      @global = locked_global_settings
      @admin&.lock!
      if expected_revision != revision
        errors.add(:base, "外观已发生变化，请刷新页面后重试")
      elsif !valid_choices?(changes)
        errors.add(:base, "外观选项无效")
      end
      raise ActiveRecord::Rollback if errors.any?

      previous = @admin ? overrides : @global.settings
      updated = reset ? {} : apply_changes(previous, changes)
      fields = (previous.keys | updated.keys).select { |key| previous[key] != updated[key] }
      if @admin
        @admin.update!(appearance_overrides: updated)
        # 迁移前启动的进程可能遗漏新列。只为实际写入的偏好签发版本。
        unless @admin.reload.appearance_overrides == updated
          errors.add(:base, "个人外观未保存，请联系管理员确认迁移并重启后台服务")
          raise ActiveRecord::Rollback
        end
      else
        @global.update!(settings: updated)
      end
      Log.record!(**audit, target: @admin || @global, details: { fields: fields })
      true
    end
  rescue ActiveRecord::ActiveRecordError
    errors.add(:base, "外观未保存，数据库写入失败，请重试")
    false
  end

  def locked_global_settings
    row = Setting.lock.find_by(key: "appearance")
    return row if row

    Setting.insert_all([ { key: "appearance" } ], unique_by: :key)
    Setting.lock.find_by!(key: "appearance")
  end

  def valid_choices?(changes)
    changes.is_a?(Hash) && changes.all? do |key, value|
      OPTIONS.key?(key) && (OPTIONS.fetch(key).key?(value) || (@admin && value.nil?))
    end
  end

  def apply_changes(previous, changes)
    inherited = @admin ? defaults : DEFAULTS
    updated = previous.dup
    changes.each do |key, value|
      if value.nil? || value == inherited.fetch(key)
        updated.delete(key)
      else
        updated[key] = value
      end
    end
    updated
  end
end
