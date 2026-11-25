class Setting < ApplicationRecord
  INTEGRATION_GROUPS = %w[active_storage tencent_cos].freeze
  SECRET_FIELDS = { "baidu_map" => %w[ak], "tencent_map" => %w[key], "wechat_component" => %w[appsecret token encoding_aes_key], "tencent_cos" => %w[secret_id secret_key endpoint],
                    "wechat_notifications" => %w[webhook_key],
                    "wechat_pay" => %w[v2_api_key v2_certificate v2_private_key v3_api_key v3_private_key verification_pem backup_verification_pem] }.freeze
  self.filter_attributes += [ :settings ]
  has_one_attached :hospital_image
  validates :key, presence: true, length: { maximum: 100 }, uniqueness: true
  validates :description, length: { maximum: 255 }
  validate do
    errors.add(:settings, "必须是 JSON 对象") unless settings.is_a?(Hash)
    self.class.secret_fields(key).each do |field|
      value = settings[field] if settings.is_a?(Hash)
      if persisted? && self.class.legacy_storage_endpoint?(key, field, value) && settings_in_database.is_a?(Hash) &&
          settings_in_database[field] == value
        next
      end
      if !value.nil? && !(value.is_a?(Hash) && value.keys == [ "ciphertext" ] && value["ciphertext"].is_a?(String))
        errors.add(:settings, "敏感字段必须加密保存")
      end
    end
  end

  def self.read_integration_value(section, field)
    record = find_by(key: section.to_s)
    decode_value(section.to_s, field.to_s, record&.settings&.fetch(field.to_s, nil))
  end

  def self.raw_snapshot
    where(key: INTEGRATION_GROUPS).order(:key).pluck(:key, :settings).to_h
  end

  def self.decode_snapshot(raw)
    raw.to_h { |section, values| [ section, values.to_h { |field, value| [ field, decode_value(section, field, value) ] } ] }
  end

  def self.secret_fields(section)
    section.to_s.start_with?("wechat_pay_profile:") ? %w[material] : SECRET_FIELDS.fetch(section.to_s, [])
  end

  def self.decode_value(section, field, value)
    return value unless secret_fields(section).include?(field) && !value.nil?
    return value if legacy_storage_endpoint?(section, field, value)

    unless value.is_a?(Hash) && value.keys == [ "ciphertext" ] && value["ciphertext"].is_a?(String)
      raise IntegrationSettings::ConfigurationError, "#{section}.#{field} 密文格式无效"
    end
    ActiveRecord::Encryption.encryptor.decrypt(value.fetch("ciphertext"))
  rescue ActiveRecord::Encryption::Errors::Base
    raise IntegrationSettings::ConfigurationError, "#{section}.#{field} 解密失败，请核对加密主密钥", cause: nil
  end

  # Older releases stored the endpoint as a public value. Continue reading it
  # while requiring encryption for any new value.
  def self.legacy_storage_endpoint?(section, field, value)
    section == "tencent_cos" && field == "endpoint" && !(value.nil? || (value.is_a?(Hash) && value.key?("ciphertext")))
  end

  def write_value(field, value)
    values = settings.deep_dup
    if value.nil?
      values.delete(field.to_s)
    elsif self.class.secret_fields(key).include?(field.to_s)
      if IntegrationSettings.redacted_value?(value)
        raise IntegrationSettings::ConfigurationError, "请填写新的凭据或留空保留"
      end
      values[field.to_s] = { "ciphertext" => ActiveRecord::Encryption.encryptor.encrypt(value) }
    else
      values[field.to_s] = value
    end
    self.settings = values
  rescue ActiveRecord::Encryption::Errors::Base
    raise IntegrationSettings::ConfigurationError, "加密主密钥未配置或无效", cause: nil
  end
end
