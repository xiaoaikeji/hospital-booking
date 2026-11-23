class WechatPaySettings
  include ActiveModel::Validations
  class Invalid < IntegrationSettings::ConfigurationError; end

  SECTION = "wechat_pay"
  VERSIONS = { "v2" => "V2", "v3" => "V3" }.freeze
  COMMON = %w[version merchant_id notify_origin].freeze
  MATERIAL = {
    "v2" => %w[v2_api_key v2_certificate v2_private_key],
    "v3" => %w[v3_api_key merchant_serial v3_private_key verification_id verification_pem]
  }.freeze
  LABELS = { "version" => "接口版本", "merchant_id" => "普通商户号", "notify_origin" => "回调域名",
    "v2_api_key" => "APIv2 密钥", "v2_certificate" => "商户 API 证书", "v2_private_key" => "商户证书私钥",
    "v3_api_key" => "APIv3 密钥", "merchant_serial" => "商户证书序列号", "verification_id" => "微信支付公钥 ID 或平台证书序列号",
    "v3_private_key" => "商户签名私钥", "verification_pem" => "微信支付公钥或平台证书" }.freeze

  def initialize(record = Setting.find_by(key: SECTION))
    @record = record
    @fields = LABELS.keys.index_with { |field| resolve(field) }
  end

  def value(field) = @fields.fetch(field).first
  def source(field) = @fields.fetch(field).last
  def stored? = @record&.settings.present?
  def revision = fingerprint([ @record&.settings || {}, @fields ])

  def save(input, actor:, request: nil)
    fields = []
    audit = { category: "settings", action: "wechat_pay.update", actor: actor, request: request }
    Setting.transaction(requires_new: true) do
      Setting.insert_all([ { key: SECTION } ], unique_by: :key)
      record = Setting.lock.find_by!(key: SECTION)
      current = self.class.new(record)
      raise Invalid, "配置已变化，请刷新后再保存" unless current.revision == input["revision"]

      if input["clear_settings"] == "1"
        fields = LABELS.keys & record.settings.keys
        fields.each { |field| record.write_value(field, nil) }
      else
        version = input.fetch("version", current.value("version"))
        raise Invalid, "请选择 V2 或 V3" unless VERSIONS.key?(version)
        fields = (COMMON + MATERIAL.fetch(version)) & input.keys
        fields = fields.select do |field|
          raise Invalid, "配置格式无效" unless input[field].is_a?(String)
          replacement = normalize(input.fetch(field))
          next false if replacement.empty? || replacement == current.value(field)
          record.write_value(field, replacement)
          true
        end
        self.class.new(record).material!
      end
      record.save!
      Log.record!(**audit, target: record, details: { fields: fields })
    end
    true
  rescue IntegrationSettings::ConfigurationError, ActiveRecord::ActiveRecordError => error
    errors.add(:base, error.is_a?(Invalid) ? error.message : "微信支付配置保存失败，请核对部署配置")
    Log.record!(**audit, status: "failed", details: { fields: fields })
    false
  end

  # Reserve an immutable, encrypted configuration even when every value came from ENV.
  # A business can commit this reference before the first request reaches WeChat.
  def reserve!
    material = material!
    ref = fingerprint(material)
    key = "wechat_pay_profile:#{ref}"
    unless Setting.exists?(key: key)
      archive = Setting.new(key: key)
      archive.write_value("material", JSON.generate(material))
      Setting.insert_all([ { key: key, settings: archive.settings } ], unique_by: :key)
    end
    material.slice("version", "merchant_id").merge("config_ref" => ref)
  end

  def self.fetch!(ref)
    raise Invalid, "支付配置引用无效" unless ref.is_a?(String) && ref.match?(/\A[a-f0-9]{64}\z/)
    json = Setting.read_integration_value("wechat_pay_profile:#{ref}", "material")
    raise Invalid, "找不到原支付配置" unless json
    JSON.parse(json)
  end

  def material!
    version = value("version")
    raise Invalid, "请选择 V2 或 V3" unless VERSIONS.key?(version)
    material = (COMMON + MATERIAL.fetch(version)).index_with do |field|
      item = value(field)
      raise Invalid, "请填写有效的#{LABELS.fetch(field)}" unless item.is_a?(String) && item.present?
      item
    end
    raise Invalid, "普通商户号格式无效" unless material["merchant_id"].match?(/\A[0-9]{1,32}\z/)
    origin = URI.parse(material["notify_origin"])
    unless origin.is_a?(URI::HTTPS) && origin.host.present? && !origin.userinfo && [ "", "/" ].include?(origin.path) && !origin.query && !origin.fragment
      raise Invalid, "回调域名须为医院公网 HTTPS 地址"
    end
    material["notify_origin"] = material["notify_origin"].delete_suffix("/")
    api_key = material.fetch("#{version}_api_key")
    raise Invalid, "API 密钥须为 32 位 ASCII 字符" unless api_key.match?(/\A[!-~]{32}\z/)
    validate_keys!(material)
    material
  rescue URI::InvalidURIError
    raise Invalid, "回调域名格式无效", cause: nil
  end

  private

  def resolve(field)
    value, source = IntegrationSettings.read_with_source(:wechat_pay, field.to_sym, env_key: "WECHAT_PAY_#{field.upcase}") do
      Setting.decode_value(SECTION, field, @record&.settings&.fetch(field, nil))
    end
    return [ "v3", "系统默认" ] if field == "version" && value.nil?
    return [ nil, "部署配置无效" ] if !value.nil? && !value.is_a?(String)
    value = normalize(value) if value
    return [ nil, "部署配置无效" ] if field == "version" && !VERSIONS.key?(value)
    source = "加密数据库" if source == "系统配置" && Setting.secret_fields(SECTION).include?(field)
    [ value, source ]
  rescue IntegrationSettings::ConfigurationError
    [ nil, "系统配置（解密失败）" ]
  end

  # Browsers submit textarea line endings as CRLF, including PEMs inherited from ENV.
  def normalize(value) = value.gsub("\r\n", "\n").strip

  def fingerprint(values)
    OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, JSON.generate(values))
  end

  def validate_keys!(material)
    version = material.fetch("version")
    private_key = OpenSSL::PKey::RSA.new(material.fetch("#{version}_private_key"), "")
    raise Invalid, "商户私钥须为 RSA 2048 位私钥" unless private_key.private? && private_key.n.num_bits == 2048
    if version == "v2"
      cert = certificate!(material.fetch("v2_certificate"))
      unless cert.check_private_key(private_key) && cert.subject.to_a.any? { |name, id, _| name == "CN" && id == material["merchant_id"] }
        raise Invalid, "商户证书与商户号或私钥不匹配"
      end
    else
      raise Invalid, "商户证书序列号格式无效" unless material["merchant_serial"].match?(/\A[0-9A-Fa-f]{1,64}\z/)
      material["merchant_serial"] = material["merchant_serial"].upcase
      id = material.fetch("verification_id")
      pem = material.fetch("verification_pem")
      if pem.start_with?("-----BEGIN CERTIFICATE-----")
        cert = certificate!(pem)
        raise Invalid, "微信支付平台证书序列号不匹配" unless cert.serial.to_s(16).casecmp?(id)
        material["verification_id"] = id.upcase
        key = cert.public_key
      else
        raise Invalid, "微信支付公钥 ID 格式无效" unless id.match?(/\APUB_KEY_ID_\d+\z/)
        key = OpenSSL::PKey::RSA.new(pem, "")
      end
      unless key.is_a?(OpenSSL::PKey::RSA) && !key.private? && key.n.num_bits == 2048 && key.n != private_key.n
        raise Invalid, "请填写微信支付的 RSA 2048 位验签公钥"
      end
    end
  rescue OpenSSL::OpenSSLError, ArgumentError
    raise Invalid, "证书或密钥的 PEM 格式无效", cause: nil
  end

  def certificate!(pem)
    cert = OpenSSL::X509::Certificate.new(pem)
    raise Invalid, "证书不在有效期内" unless Time.current.between?(cert.not_before, cert.not_after)
    cert
  end
end
