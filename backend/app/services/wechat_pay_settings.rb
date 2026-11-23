class WechatPaySettings
  include ActiveModel::Validations
  class Invalid < IntegrationSettings::ConfigurationError
    attr_reader :field

    def initialize(message, field: :base)
      @field = field
      super(message)
    end
  end

  SECTION = "wechat_pay"
  VERSIONS = { "v2" => "V2", "v3" => "V3" }.freeze
  COMMON = %w[version merchant_id notify_origin].freeze
  V2_TLS = %w[v2_certificate v2_private_key].freeze
  BACKUP = %w[backup_verification_id backup_verification_pem].freeze
  MATERIAL = {
    "v2" => %w[v2_api_key v2_certificate v2_private_key],
    "v3" => %w[v3_api_key merchant_serial v3_private_key verification_id verification_pem] + BACKUP
  }.freeze
  LABELS = { "version" => "接口版本", "merchant_id" => "普通商户号", "notify_origin" => "回调域名",
    "v2_api_key" => "APIv2 密钥", "v2_certificate" => "商户 API 证书", "v2_private_key" => "商户证书私钥",
    "v3_api_key" => "APIv3 密钥", "merchant_serial" => "商户证书序列号", "verification_id" => "微信支付公钥 ID 或平台证书序列号",
    "v3_private_key" => "商户签名私钥", "verification_pem" => "微信支付公钥或平台证书",
    "backup_verification_id" => "备用公钥 ID 或平台证书序列号", "backup_verification_pem" => "备用微信支付公钥或平台证书" }.freeze

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
      record = locked_settings
      current = self.class.new(record)
      raise Invalid, "配置已变化，请刷新后再保存" unless current.revision == input["revision"]

      # Capture deployments and profiles created before the per-merchant registry existed.
      previous = current.configured_material
      remember!(previous) if previous
      if input["clear_settings"] == "1"
        fields = record.settings.keys
        fields.each { |field| record.write_value(field, nil) }
      else
        fields = update_fields!(record, current, input)
        remember!(self.class.new(record).material!)
      end
      record.save!
      Log.record!(**audit, target: record, details: { fields: fields })
    end
    true
  rescue IntegrationSettings::ConfigurationError, ActiveRecord::ActiveRecordError => error
    errors.add(error.is_a?(Invalid) ? error.field : :base, error.is_a?(Invalid) ? error.message : "微信支付配置保存失败，请核对部署配置")
    Log.record!(**audit, status: "failed", details: { fields: fields })
    false
  end

  # Reserve an immutable, encrypted configuration even when every value came from ENV.
  # A business can commit this reference before the first request reaches WeChat.
  def reserve!
    Setting.transaction do
      material = self.class.new(locked_settings).material!(check_optional: false)
      material.slice("version", "merchant_id").merge("config_ref" => remember!(material))
    end
  end

  def self.fetch!(ref)
    raise Invalid, "支付配置引用无效" unless ref.is_a?(String) && ref.match?(/\A[a-f0-9]{64}\z/)
    original = archived!(ref)
    version, merchant = original.values_at("version", "merchant_id")
    active = new
    latest = if [ active.value("version"), active.value("merchant_id") ] == [ version, merchant ]
      active.material!(check_optional: false)
    elsif (current_ref = Setting.read_integration_value(registry_key(version, merchant), "ref"))
      archived!(current_ref)
    else
      # Legacy inactive merchants have only encrypted immutable profiles, with no index.
      Setting.where("key LIKE 'wechat_pay_profile:%'").order(created_at: :desc, id: :desc).lazy.map do |record|
        JSON.parse(Setting.decode_value(record.key, "material", record.settings.fetch("material")))
      end.find { |item| item.values_at("version", "merchant_id") == [ version, merchant ] }
    end
    raise Invalid, "找不到原商户的支付配置" unless latest && latest.values_at("version", "merchant_id") == [ version, merchant ]
    latest.merge("notify_origin" => original.fetch("notify_origin"))
  end

  def self.archived!(ref)
    json = Setting.read_integration_value("wechat_pay_profile:#{ref}", "material")
    raise Invalid, "找不到原支付配置" unless json
    JSON.parse(json)
  end

  def self.registry_key(version, merchant) = "wechat_pay_current:#{version}:#{merchant}"

  def configured_material
    material!(check_optional: false) if value("merchant_id").present?
  rescue Invalid
    # A partial or invalid deployment can still be replaced in the settings form.
    nil
  end

  def v2_refund_problem
    self.class.refund_tls!((V2_TLS + %w[merchant_id]).index_with { |field| value(field) })
    nil
  rescue Invalid => error
    error.message
  end

  def material!(check_optional: true)
    version = value("version")
    raise Invalid, "请选择 V2 或 V3" unless VERSIONS.key?(version)
    material = (COMMON + MATERIAL.fetch(version)).index_with do |field|
      item = value(field)
      unless (V2_TLS + BACKUP).include?(field) || (item.is_a?(String) && item.present?)
        raise Invalid.new("请填写有效的#{LABELS.fetch(field)}", field: field)
      end
      item
    end.compact
    raise Invalid, "普通商户号格式无效" unless material["merchant_id"].match?(/\A[0-9]{1,32}\z/)
    origin = URI.parse(material["notify_origin"])
    unless origin.is_a?(URI::HTTPS) && origin.host.present? && !origin.userinfo && [ "", "/" ].include?(origin.path) && !origin.query && !origin.fragment
      raise Invalid, "回调域名须为医院公网 HTTPS 地址"
    end
    material["notify_origin"] = material["notify_origin"].delete_suffix("/")
    api_key = material.fetch("#{version}_api_key")
    raise Invalid, "API 密钥须为 32 位 ASCII 字符" unless api_key.match?(/\A[!-~]{32}\z/)
    if version == "v2"
      self.class.refund_tls!(material) if check_optional && V2_TLS.any? { |field| material.key?(field) }
    else
      validate_v3!(material, check_dates: check_optional)
    end
    material
  rescue URI::InvalidURIError
    raise Invalid, "回调域名格式无效", cause: nil
  end

  def self.refund_tls!(material)
    V2_TLS.each do |field|
      raise Invalid.new("发起退款前请在「微信支付」补齐#{LABELS.fetch(field)}", field: field) if material[field].blank?
    end
    cert = certificate!(material.fetch("v2_certificate"), "v2_certificate")
    unless cert.subject.to_a.any? { |name, id, _| name == "CN" && id == material.fetch("merchant_id") }
      raise Invalid.new("商户 API 证书的商户号与配置不匹配", field: "v2_certificate")
    end
    key = private_key!(material, "v2_private_key")
    raise Invalid.new("商户证书私钥与商户 API 证书不匹配", field: "v2_private_key") unless cert.check_private_key(key)
    { client_cert: cert, client_key: key }
  end

  def self.private_key!(material, field)
    key = OpenSSL::PKey::RSA.new(material.fetch(field), "")
    return key if key.private? && key.n.num_bits == 2048
    raise Invalid.new("请填写 RSA 2048 位商户私钥", field: field)
  rescue OpenSSL::OpenSSLError, ArgumentError
    raise Invalid.new("商户私钥的 PEM 格式无效", field: field), cause: nil
  end

  def self.certificate!(pem, field, check_dates: true)
    cert = OpenSSL::X509::Certificate.new(pem)
    if check_dates && !Time.current.between?(cert.not_before, cert.not_after)
      raise Invalid.new("#{LABELS.fetch(field)}不在有效期内，请更新证书", field: field)
    end
    cert
  rescue OpenSSL::OpenSSLError
    raise Invalid.new("证书的 PEM 格式无效", field: field), cause: nil
  end

  private

  def locked_settings
    Setting.insert_all([ { key: SECTION } ], unique_by: :key)
    Setting.lock.find_by!(key: SECTION)
  end

  def update_fields!(record, current, input)
    version = input.fetch("version", current.value("version"))
    raise Invalid, "请选择 V2 或 V3" unless VERSIONS.key?(version)
    fields = (COMMON + MATERIAL.fetch(version)) & input.keys
    raise Invalid, "配置格式无效" unless fields.all? { |field| input[field].is_a?(String) }
    fields = fields.select { |field| normalize(input.fetch(field)).present? && normalize(input.fetch(field)) != current.value(field) }
    if fields.include?("merchant_id") && current.value("merchant_id").present?
      # The browser resubmits the previous merchant's visible values. Only an
      # explicit change can provision credentials for the replacement merchant.
      record.write_value("deployment_merchant", current.value("merchant_id")) unless record.settings["deployment_merchant"]
      (MATERIAL.values.flatten + %w[backup_disabled v2_tls_disabled]).each { |field| record.write_value(field, nil) }
    end
    fields.each { |field| record.write_value(field, normalize(input.fetch(field))) }
    optional, flag, remove = if version == "v2"
      [ V2_TLS, "v2_tls_disabled", "remove_v2_certificate" ]
    else
      [ BACKUP, "backup_disabled", "remove_backup" ]
    end
    if input[remove] == "1"
      optional.each { |field| record.write_value(field, nil) }
      record.write_value(flag, true)
      fields |= optional
    elsif fields.intersect?(optional)
      record.write_value(flag, nil)
    end
    fields
  end

  def archive!(material)
    ref = fingerprint(material)
    key = "wechat_pay_profile:#{ref}"
    unless Setting.exists?(key: key)
      archive = Setting.new(key: key)
      archive.write_value("material", JSON.generate(material))
      Setting.insert_all([ { key: key, settings: archive.settings } ], unique_by: :key)
    end
    ref
  end

  def remember!(material)
    record = Setting.find_or_initialize_by(key: self.class.registry_key(*material.values_at("version", "merchant_id")))
    ref = archive!(material)
    record.write_value("ref", ref)
    record.save! if record.changed?
    ref
  end

  def resolve(field)
    return [ nil, "未配置" ] if (BACKUP.include?(field) && @record&.settings&.[]("backup_disabled")) ||
      (V2_TLS.include?(field) && @record&.settings&.[]("v2_tls_disabled"))
    value, source = IntegrationSettings.read_with_source(:wechat_pay, field.to_sym, env_key: "WECHAT_PAY_#{field.upcase}") do
      Setting.decode_value(SECTION, field, @record&.settings&.fetch(field, nil))
    end
    if !COMMON.include?(field) && [ "环境变量", "Rails credentials" ].include?(source)
      owner = IntegrationSettings.read_with_source(:wechat_pay, :merchant_id, env_key: "WECHAT_PAY_MERCHANT_ID") { nil }.first ||
        @record&.settings&.[]("deployment_merchant")
      return [ nil, "未配置" ] if owner && @record&.settings&.[]("merchant_id").present? && owner != @record.settings["merchant_id"]
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

  def validate_v3!(material, check_dates:)
    private_key = self.class.private_key!(material, "v3_private_key")
    raise Invalid, "商户证书序列号格式无效" unless material["merchant_serial"].match?(/\A[0-9A-Fa-f]{1,64}\z/)
    material["merchant_serial"] = material["merchant_serial"].upcase
    [ %w[verification_id verification_pem], BACKUP ].each do |id_field, pem_field|
      id, pem = material.values_at(id_field, pem_field)
      next unless id || pem
      raise Invalid.new("请补齐验签材料的 ID 或序列号", field: id_field) unless id
      raise Invalid.new("请补齐对应的微信支付验签材料", field: pem_field) unless pem
      if pem.start_with?("-----BEGIN CERTIFICATE-----")
        cert = self.class.certificate!(pem, pem_field, check_dates: check_dates)
        raise Invalid.new("微信支付平台证书序列号不匹配", field: id_field) unless cert.serial.to_s(16).casecmp?(id)
        material[id_field] = id.upcase
        key = cert.public_key
      else
        raise Invalid.new("微信支付公钥 ID 格式无效", field: id_field) unless id.match?(/\APUB_KEY_ID_\d+\z/)
        key = OpenSSL::PKey::RSA.new(pem, "")
      end
      unless key.is_a?(OpenSSL::PKey::RSA) && !key.private? && key.n.num_bits == 2048 && key.n != private_key.n
        raise Invalid.new("请填写微信支付的 RSA 2048 位验签公钥", field: pem_field)
      end
    rescue OpenSSL::OpenSSLError, ArgumentError
      raise Invalid.new("验签材料的 PEM 格式无效", field: pem_field), cause: nil
    end
    if material["verification_id"] == material["backup_verification_id"]
      raise Invalid.new("主备验签材料的标识须不同", field: "backup_verification_id")
    end
  end
end
