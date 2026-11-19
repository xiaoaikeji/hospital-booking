class AppConfiguration
  class Invalid < StandardError; end

  def initialize(app)
    @app = app
  end

  def credential
    database = @app.appsecret
    return [ database, "加密数据库" ] if database.present?
    key = "MINI_APP_#{@app.provider.to_s.upcase}_#{@app.appid}_APPSECRET"
    return [ ENV[key], "环境变量" ] if ENV[key].present?
    value = Rails.application.credentials.dig(:mini_apps, @app.provider.to_s.to_sym, @app.appid.to_s.to_sym, :appsecret)
    return [ nil, "未配置" ] if IntegrationSettings.unset?(value)
    raise Invalid, "部署凭据格式无效" unless value.is_a?(String)
    [ value, "Rails credentials" ]
  rescue ActiveRecord::Encryption::Errors::Base
    raise Invalid, "应用密钥解密失败，请核对加密主密钥", cause: nil
  end

  def digest(value)
    OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, value.to_json)
  end

  def revision
    digest([ @app.id, @app.lock_version, *credential ])
  end

  def credential_status
    value = credential.first
    return "未配置" if value.blank?
    @app.verified_digest == digest(value) ? "已验证" : "已填写，待验证"
  end

  def verify!
    value = credential.first
    raise Invalid, "请先配置本应用的 AppSecret" if value.blank?
    client = @app.provider == "wechat" ? Wechat::CredentialClient : Douyin::CredentialClient
    client.new.verify!(@app.appid, value)
    @app.verified_digest = digest(value)
  end

  def assign(input)
    old = credential.first
    @app.appsecret = nil if input[:clear_secret] == "1"
    if input[:clear_secret] != "1" && input[:appsecret].present? && input[:appsecret] != old
      value = input[:appsecret]
      raise Invalid, "密钥格式无效" if value.length > 4096 || value.match?(/\s/)
      @app.appsecret = value
    end
    @app.verified_digest = nil if old != credential.first
  end
end
