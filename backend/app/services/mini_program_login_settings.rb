class MiniProgramLoginSettings
  include ActiveModel::Model

  class Invalid < StandardError; end
  FIELD = "unionid_app_groups"

  attr_reader :apps

  def initialize
    load_settings
  end

  def self.trusted_group(appid, lock: false)
    values = Setting.where(key: "wechat").lock(lock).pick(:settings)
    groups(values&.[](FIELD)).find { |group| group.include?(appid) }
  end

  def self.groups(value)
    return [] unless value.is_a?(Array) && value.all? { |group| group.is_a?(Array) && group.all?(String) }
    members = value.flatten
    members.uniq.size == members.size ? value : []
  end

  def groups = self.class.groups(value)
  def group_slots = 1..[ groups.size, (apps.size + 1) / 2, 1 ].max
  def group_number(appid) = groups.index { |group| group.include?(appid) }&.next

  def revision
    Digest::SHA256.hexdigest([ "wechat", value, apps.map(&:appid) ].to_json)
  end

  def save(input, expected_revision:, actor:, request:)
    audit = { category: "app", action: "app.user_sharing", actor: actor, request: request }
    Setting.transaction(requires_new: true) do
      load_settings(lock: true)
      unless @record
        Setting.insert_all([ { key: "wechat" } ], unique_by: :key)
        @record = Setting.lock.find_by!(key: "wechat")
      end
      raise Invalid, "配置已变化，请核对当前设置后再保存" unless expected_revision == revision

      updated = parse_groups(input)
      fields = []
      if updated != @record.settings.fetch(FIELD, [])
        reset_changed_unionids(updated)
        @record.write_value(FIELD, updated)
        @record.save!
        fields << FIELD
      end
      Log.record!(**audit, target: @record, details: { fields: fields })
    end
    true
  rescue Invalid, ActiveRecord::ActiveRecordError => error
    reason = error.is_a?(Invalid) ? error.message : "设置未保存，数据库写入失败，请重试"
    load_settings
    errors.add(:base, reason)
    Log.record!(**audit, target: @record, status: "failed", details: { fields: [ FIELD ], reason: reason })
    false
  end

  private

  def value = @record&.settings&.[](FIELD)

  def load_settings(lock: false)
    # App deletion and login also take the app lock first. Keep membership stable through commit.
    @apps = App.wechat_mini_programs.select(:id, :appid, :nickname).order(:id).lock(lock).to_a
    @record = Setting.lock(lock).find_by(key: "wechat")
  end

  def parse_groups(input)
    unless input.is_a?(Hash) && input.keys.sort == apps.map(&:appid).sort
      raise Invalid, "请为列表中的每个微信小程序选择共享组或独立登录"
    end
    allowed = group_slots.map(&:to_s)
    slots = []
    input.each do |appid, number|
      next if number == "0"
      raise Invalid, "共享组无效，请重新选择" unless allowed.include?(number)
      (slots[number.to_i - 1] ||= []) << appid
    end
    slots.map { |members| Array(members).sort }
  end

  def reset_changed_unionids(updated)
    # Joining from independent login also requires a fresh UnionID from the verified Open Platform account.
    newly_grouped = updated.flatten - groups.flatten
    departed = groups.each_with_index.flat_map do |members, index|
      next [] if updated.any? { |new_members| members.sort == new_members }
      members - Array(updated[index])
    end
    eligible = (departed | newly_grouped) & apps.map(&:appid)
    UserApp.where(provider: "wechat", appid: eligible).where.not(unionid: nil).update_all(unionid: nil) if eligible.any?
  end
end
