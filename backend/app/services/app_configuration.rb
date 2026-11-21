class AppConfiguration
  class Invalid < StandardError; end
  class DecryptionFailed < Invalid; end
  class EncryptionUnavailable < Invalid; end

  CALLBACK_FIELDS = %i[callback_token callback_encoding_aes_key].freeze
  SECRET_FIELDS = [:appsecret, *CALLBACK_FIELDS].freeze
  DAMAGED_SOURCE = "系统配置（解密失败）"
  ENCRYPTION_UNAVAILABLE = "无法确认系统加密主密钥，请核对部署配置"

  def initialize(app)
    @app = app
  end

  def credential(field = :appsecret)
    database = @app.public_send(field)
    return [database, "加密数据库"] if database.present?

    key = "MINI_APP_#{@app.provider.to_s.upcase}_#{@app.appid}_#{field.to_s.upcase}"
    return [ENV[key], "环境变量"] if ENV[key].present?

    value = Rails.application.credentials.dig(:mini_apps, @app.provider.to_s.to_sym, @app.appid.to_s.to_sym, field)
    return [nil, "未配置"] if IntegrationSettings.unset?(value)
    raise Invalid, "部署凭据格式无效" unless value.is_a?(String)

    [value, "Rails credentials"]
  rescue ActiveRecord::Encryption::Errors::Decryption
    raise DecryptionFailed, "应用凭据解密失败，请核对加密主密钥", cause: nil
  rescue ActiveRecord::Encryption::Errors::Base
    raise EncryptionUnavailable, ENCRYPTION_UNAVAILABLE, cause: nil
  end

  def editable_credentials
    fields.index_with do |field|
      credential(field)
    rescue DecryptionFailed
      raise EncryptionUnavailable, ENCRYPTION_UNAVAILABLE, cause: nil unless repairable_ciphertext?(field)

      [nil, DAMAGED_SOURCE]
    end
  end

  def callback_credentials!
    token, key = CALLBACK_FIELDS.map { |field| credential(field).first }
    unless @app.wechat_original_id.present? && token.to_s.match?(/\A[A-Za-z0-9]{3,32}\z/) && Wechat::MessageCrypto.valid_key?(key)
      raise Invalid, "请核对公众号原始 ID、回调 Token 和消息加解密密钥"
    end

    { appid: @app.appid, token: token, encoding_aes_key: key }
  end

  def digest(value)
    OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, value.to_json)
  end

  def revision(snapshot = editable_credentials)
    versions = snapshot.map do |field, (value, source)|
      value = @app.read_attribute_before_type_cast(field) if source == DAMAGED_SOURCE
      [field, value, source]
    end
    digest([@app.id, @app.lock_version, versions])
  end

  def disable_revision
    digest(["disable", @app.id, @app.lock_version, @app.status])
  end

  def credential_status
    value = credential.first
    return "未配置" if value.blank?

    @app.verified_digest == digest(value) ? "已验证" : "已填写，待验证"
  rescue Invalid => error
    error.message
  end

  def verify!
    value = credential.first.presence || raise(Invalid, "请先配置本应用的 AppSecret")
    client = { "wechat" => Wechat::CredentialClient, "douyin" => Douyin::CredentialClient }.fetch(@app.provider) do
      raise Invalid, "应用平台无效"
    end
    result = client.new.verify!(@app.appid, value)
    if @app.provider == "wechat"
      # Cache the verified token only after the credentials, application ID and audit log have committed.
      ActiveRecord.after_all_transactions_commit { Wechat::AccessToken.store(@app, value, result, unless_exist: true) }
    end
    @app.verified_digest = digest(value)
  end

  def assign(input, snapshot:)
    changes = snapshot.filter_map do |field, (old, source)|
      clear = input[field == :appsecret ? :clear_secret : :clear_callback] == "1"
      if clear
        [field, nil] if source.in?(["加密数据库", DAMAGED_SOURCE])
      else
        value = input[field].presence
        [field, value] if value && value != old
      end
    end.to_h
    if changes[:appsecret] && (changes[:appsecret].length > 4096 || changes[:appsecret].match?(/\s/))
      raise Invalid, "AppSecret 格式无效"
    end

    repaired = changes.keys.select { |field| snapshot.fetch(field).last == DAMAGED_SOURCE }
    if repaired.any?
      # Dirty tracking decrypts the old value. This repair runs inside the caller's locked transaction.
      replacement = changes.slice(*repaired)
      replacement[:verified_digest] = nil if repaired.include?(:appsecret)
      unless @app.update_columns(**replacement, lock_version: @app.lock_version + 1, touch: true)
        raise ActiveRecord::StaleObjectError.new(@app, "update")
      end
    end
    @app.assign_attributes(changes.except(*repaired))
    if changes.key?(:appsecret) && snapshot.fetch(:appsecret).first != credential.first
      @app.verified_digest = nil
    end

    if (changes.keys & CALLBACK_FIELDS).any? || @app.will_save_change_to_wechat_original_id?
      configured = CALLBACK_FIELDS.any? { |field| credential(field).first.present? }
      callback_credentials! if configured
    end
    repaired
  end

  private

  def fields = @app.wechat_official_account? ? SECRET_FIELDS : [:appsecret]

  def repairable_ciphertext?(damaged_field)
    encryption = ActiveRecord::Encryption
    encryption.config.primary_key
    encryption.config.key_derivation_salt
    encryption.key_provider.encryption_key

    references = []
    App.select(:id, *SECRET_FIELDS).find_each do |record|
      SECRET_FIELDS.each do |field|
        next if record.id == @app.id && field == damaged_field
        value = record.read_attribute_before_type_cast(field)
        references << value if value.present?
      end
    end
    Setting.where(key: Setting::SECRET_FIELDS.keys).pluck(:key, :settings).each do |section, values|
      Setting::SECRET_FIELDS.fetch(section).each do |field|
        value = values[field]
        references << value["ciphertext"] if value.is_a?(Hash) && value["ciphertext"].is_a?(String)
      end
    end

    # With no other ciphertext to authenticate against, the envelope must prove damage.
    return !@app.encrypted_attribute?(damaged_field) if references.empty?

    references.any? do |ciphertext|
      encryption.encryptor.decrypt(ciphertext)
      true
    rescue ActiveRecord::Encryption::Errors::Decryption
      false
    end
  rescue ActiveRecord::Encryption::Errors::Base
    false
  end
end
