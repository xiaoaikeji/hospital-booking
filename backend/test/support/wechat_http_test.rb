module WechatHttpTest
  class Adapter < Faraday::Adapter::Test
    class_attribute :stubs
    def initialize(app) = super(app, self.class.stubs)
  end

  def install_wechat_stubs
    @previous_adapter, @previous_cache = Faraday.default_adapter, Rails.cache
    @stubs = Faraday::Adapter::Test::Stubs.new
    Adapter.stubs = @stubs
    Faraday.default_adapter = Adapter
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  def remove_wechat_stubs
    Faraday.default_adapter = @previous_adapter
    Rails.cache = @previous_cache
  end

  def response_for(data)
    [200, { "Content-Type" => "application/json" }, data.to_json]
  end

  def direct_token_key(app, secret = AppConfiguration.new(app).credential.first)
    "#{Wechat::AccessToken.cache_prefix(app, secret)}/access_token"
  end

  def configure_account(app)
    fields = { status: "active", appsecret: "demo-secret-#{app.appid}" }
    if app.wechat_official_account?
      fields.merge!(wechat_original_id: "gh_#{app.appid}", callback_token: "Demo#{app.id}Token",
        callback_encoding_aes_key: Base64.strict_encode64(Digest::SHA256.digest(app.appid)).delete_suffix("="))
    end
    app.update!(fields)
    Rails.cache.write(direct_token_key(app), app.appid)
    app
  end

  # Independent encoding of a platform push, including the receiving AppID after the XML.
  def signed_push(path, xml, account: @a, tamper: false, frame_appid: account.appid)
    message = "0" * 16 + [xml.bytesize].pack("N") + xml.b + frame_appid.b
    pad = 32 - message.bytesize % 32
    key = Base64.strict_decode64("#{account.callback_encoding_aes_key}=")
    cipher = OpenSSL::Cipher.new("aes-256-cbc").encrypt
    cipher.key = key
    cipher.iv = key.byteslice(0, 16)
    cipher.padding = 0
    encrypted = Base64.strict_encode64(cipher.update(message + pad.chr * pad) + cipher.final)
    time, nonce = Time.current.to_i.to_s, "demo-nonce"
    signature = Digest::SHA1.hexdigest([account.callback_token, time, nonce, encrypted].sort.join)
    query = { timestamp: time, nonce: nonce, msg_signature: tamper ? "invalid" : signature }
    post "#{path}?#{query.to_query}", params: "<xml><Encrypt>#{encrypted}</Encrypt></xml>", headers: { "CONTENT_TYPE" => "text/xml" }
  end
end
