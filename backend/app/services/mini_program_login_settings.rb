class MiniProgramLoginSettings
  include ActiveModel::Model

  class Invalid < StandardError; end
  SECTIONS = {
    "appointment" => %w[require_mobile_auth settings appointment.phone_policy],
    "wechat" => %w[unionid_app_groups app app.user_sharing]
  }.freeze

  attr_reader :apps

  def initialize(section)
    @section = section
    @field, @category, @action = SECTIONS.fetch(section)
    load_settings
  end

  def self.trusted_group(appid, lock: false)
    values = Setting.where(key: "wechat").lock(lock).pick(:settings)
    groups(values&.fetch("unionid_app_groups", nil)).find { |group| group.include?(appid) }
  end

  def self.groups(value)
    return [] unless value.is_a?(Array) && value.all? { |group| group.is_a?(Array) && group.all?(String) }
    members = value.flatten
    members.uniq.size == members.size ? value : []
  end

  def phone_required? = ActiveModel::Type::Boolean.new.cast(value) == true
  def groups = self.class.groups(value)
  def group_slots = 1..[ groups.size, (apps.size + 1) / 2, 1 ].max
  def group_number(appid) = groups.index { |group| group.include?(appid) }&.next

  def revision
    Digest::SHA256.hexdigest([ @section, value, apps.map(&:appid) ].to_json)
  end

  def save(input, expected_revision:, actor:, request:)
    audit = { category: @category, action: @action, actor: actor, request: request }
    Setting.transaction(requires_new: true) do
      load_settings(lock: true)
      unless @record
        Setting.insert_all([ { key: @section } ], unique_by: :key)
        @record = Setting.lock.find_by!(key: @section)
      end
      raise Invalid, "配置已变化，请核对当前设置后再保存" unless expected_revision == revision

      updated = sharing? ? parse_groups(input) : parse_phone_policy(input)
      fields = []
      previous = @record.settings.fetch(@field) { sharing? ? [] : false }
      if updated != previous
        forget_departed_unionids(updated) if sharing?
        @record.write_value(@field, updated)
        @record.save!
        fields << @field
      end
      Log.record!(**audit, target: @record, details: { fields: fields })
    end
    true
  rescue Invalid, ActiveRecord::ActiveRecordError => error
    reason = error.is_a?(Invalid) ? error.message : "设置未保存，数据库写入失败，请重试"
    load_settings
    errors.add(:base, reason)
    Log.record!(**audit, target: @record, status: "failed", details: { fields: [ @field ], reason: reason })
    false
  end

  private

  def sharing? = @section == "wechat"
  def value = @record&.settings&.fetch(@field, nil)

  def load_settings(lock: false)
    # App deletion and login also take the app lock first. Keep membership stable through commit.
    @apps = sharing? ? App.wechat_mini_programs.select(:id, :appid, :nickname).order(:id).lock(lock).to_a : []
    @record = Setting.lock(lock).find_by(key: @section)
  end

  def parse_phone_policy(input)
    return false if input == "0"
    return true if input == "1"
    raise Invalid, "请选择是否验证账号手机号"
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

  def forget_departed_unionids(updated)
    # A UnionID belongs to its previous Open Platform account. Existing OpenID bindings stay valid.
    departed = groups.each_with_index.flat_map do |members, index|
      next [] if updated.any? { |new_members| members.sort == new_members }
      members - Array(updated[index])
    end
    eligible = departed & apps.map(&:appid)
    UserApp.where(provider: "wechat", appid: eligible).where.not(unionid: nil).update_all(unionid: nil) if eligible.any?
  end
end
