class MapSettings
  include ActiveModel::Validations
  class Invalid < StandardError; end
  attr_reader :key, :source

  def initialize(row = Setting.find_by(key: "baidu_map"))
    @stored = row&.settings&.fetch("ak", nil)
    @key, @source = [
      [ Setting.decode_value("baidu_map", "ak", @stored), "加密数据库" ],
      [ ENV["BAIDU_MAP_AK"], "环境变量" ], [ Rails.application.credentials.dig(:baidu_map, :ak), "Rails credentials" ]
    ].find { |value, _| value.is_a?(String) && value.present? } || [ nil, "未配置" ]
  rescue IntegrationSettings::ConfigurationError
    @source = "系统配置（解密失败）"
  end

  def stored? = @stored.present?
  def revision = OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, [ @stored, key, source ].to_json)

  def save(input, actor:, request:)
    audit = { category: "settings", action: "map_settings.update", actor: actor, request: request }
    Setting.transaction(requires_new: true) do
      Setting.insert_all([ { key: "baidu_map" } ], unique_by: :key)
      row = Setting.lock.find_by!(key: "baidu_map")
      current = self.class.new(row)
      raise Invalid, "配置已变化，请刷新后再保存" unless current.revision == input[:revision]
      fields = []
      replacement = input[:ak].to_s.strip
      if input[:clear_key] == "1"
        fields << "ak" if current.stored?
        row.write_value("ak", nil)
      elsif replacement.present?
        raise Invalid, "请填写有效的百度地图服务端 AK" unless replacement.match?(/\A[A-Za-z0-9_-]{1,128}\z/)
        if replacement != current.key
          row.write_value("ak", replacement)
          fields << "ak"
        end
      elsif current.stored? && current.key.blank?
        raise Invalid, "请重新填写地图 AK 或清除系统配置"
      end
      row.save!
      Log.record!(**audit, target: row, details: { fields: fields })
    end
    true
  rescue Invalid, IntegrationSettings::ConfigurationError, ActiveRecord::ActiveRecordError => error
    reason = error.is_a?(Invalid) ? error.message : "地图设置未保存，请核对部署配置"
    errors.add(:base, reason)
    Log.record!(**audit, target: Setting.find_by(key: "baidu_map"), status: "failed", details: { fields: %w[ak] })
    false
  end
end
