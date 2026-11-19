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
    @component = { appid: "wxPlatform", appsecret: "demo-component-secret", token: "demo-verify-token",
      encoding_aes_key: Base64.strict_encode64("x" * 32).delete_suffix("=") }
    @previous_env = {}
    @component.each do |key, value|
      name = "WECHAT_COMPONENT_#{key.upcase}"
      @previous_env[name] = ENV[name]
      ENV[name] = value
    end
  end

  def remove_wechat_stubs
    Faraday.default_adapter = @previous_adapter
    Rails.cache = @previous_cache
    @previous_env.each { |key, value| ENV[key] = value }
  end

  def response_for(data)
    [ 200, { "Content-Type" => "application/json" }, data.to_json ]
  end

  def signed_push(path, xml, tamper: false)
    message = "0" * 16 + [ xml.bytesize ].pack("N") + xml + @component[:appid]
    pad = 32 - message.bytesize % 32
    cipher = OpenSSL::Cipher.new("aes-256-cbc").encrypt
    cipher.key = "x" * 32
    cipher.iv = "x" * 16
    cipher.padding = 0
    encrypted = Base64.strict_encode64(cipher.update(message + pad.chr * pad) + cipher.final)
    time, nonce = Time.current.to_i.to_s, "demo-nonce"
    signature = Digest::SHA1.hexdigest([ @component[:token], time, nonce, encrypted ].sort.join)
    query = { timestamp: time, nonce: nonce, msg_signature: tamper ? "invalid" : signature }
    post "#{path}?#{query.to_query}", params: "<xml><Encrypt>#{encrypted}</Encrypt></xml>", headers: { "CONTENT_TYPE" => "text/xml" }
  end
end
