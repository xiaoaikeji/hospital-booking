require "openssl"
require "base64"

module WechatPayProtocol
  # Fresh material for the test merchant and the independent WeChat signer.
  def generate_payment_keys
    @merchant_id = "1900000001"
    @merchant_key = OpenSSL::PKey::RSA.generate(2048)
    @wechat_key = OpenSSL::PKey::RSA.generate(2048)
    @certificate = payment_certificate(@merchant_key, @merchant_id)
    @v2_key, @v3_key = SecureRandom.hex(16), SecureRandom.hex(16)
    @key_id = "PUB_KEY_ID_123456"
  end

  def payment_certificate(key, name)
    OpenSSL::X509::Certificate.new.tap do |cert|
      cert.version, cert.serial = 2, SecureRandom.random_number(2**120) + 1
      cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=#{name}")
      cert.public_key = key.public_key
      cert.not_before, cert.not_after = 1.day.ago, 1.year.from_now
      cert.sign(key, OpenSSL::Digest.new("SHA256"))
    end
  end

  def payment_settings(version)
    fields = if version == "v2"
      { "v2_api_key" => @v2_key, "v2_certificate" => @certificate.to_pem, "v2_private_key" => @merchant_key.to_pem }
    else
      { "v3_api_key" => @v3_key, "merchant_serial" => @certificate.serial.to_s(16).upcase, "v3_private_key" => @merchant_key.to_pem,
        "verification_id" => @key_id, "verification_pem" => @wechat_key.public_key.to_pem }
    end
    fields.merge("version" => version, "merchant_id" => @merchant_id, "notify_origin" => "https://booking.example.org")
  end

  def xml(fields, root = "xml")
    fields.stringify_keys.transform_values(&:to_s).to_xml(root: root, skip_types: true, dasherize: false)
  end

  def v2_signature(fields)
    entries = fields.except("sign").select { |_, v| v.present? }.sort.map { |entry| entry.join("=") }
    OpenSSL::HMAC.hexdigest("SHA256", @v2_key, "#{entries.join("&")}&key=#{@v2_key}").upcase
  end

  def signed_xml(data)
    fields = { "return_code" => "SUCCESS", "result_code" => "SUCCESS", "nonce_str" => SecureRandom.hex(12),
      "mch_id" => @merchant_id, "appid" => @mini_program.appid }.merge(data)
    xml(fields.merge("sign" => v2_signature(fields)))
  end

  def v3_headers(body, timestamp: Time.current.to_i.to_s, nonce: SecureRandom.hex(8))
    signature = @wechat_key.sign("SHA256", [ timestamp, nonce, body, "" ].join("\n"))
    { "Wechatpay-Timestamp" => timestamp, "Wechatpay-Nonce" => nonce, "Wechatpay-Serial" => @key_id,
      "Wechatpay-Signature" => Base64.strict_encode64(signature) }
  end

  def notification_packet(version, kind, data)
    if version == "v2"
      body = if kind == "payment"
        signed_xml(data)
      else
        cipher = OpenSSL::Cipher.new("aes-256-ecb").encrypt
        cipher.key = Digest::MD5.hexdigest(@v2_key)
        info = Base64.strict_encode64(cipher.update(xml(data, "root")) + cipher.final)
        xml("return_code" => "SUCCESS", "appid" => @mini_program.appid, "mch_id" => @merchant_id, "req_info" => info)
      end
      return [ body, { "Content-Type" => "text/xml" } ]
    end
    type = kind == "payment" ? "transaction" : "refund"
    nonce = SecureRandom.hex(6)
    cipher = OpenSSL::Cipher.new("aes-256-gcm").encrypt
    cipher.key, cipher.iv, cipher.auth_data = @v3_key, nonce, type
    encrypted = cipher.update(JSON.generate(data)) + cipher.final + cipher.auth_tag
    event = kind == "payment" ? "TRANSACTION.SUCCESS" : "REFUND.#{data.fetch("refund_status")}"
    body = JSON.generate(resource_type: "encrypt-resource", event_type: event,
      resource: { algorithm: "AEAD_AES_256_GCM", original_type: type, associated_data: type, nonce: nonce,
        ciphertext: Base64.strict_encode64(encrypted) })
    [ body, v3_headers(body).merge("Content-Type" => "application/json") ]
  end

  # Exercise the production Faraday connection, including V2 refund client TLS.
  # The stub verifies the outbound wire representation before signing its response.
  def stub_wechat(version, method, path, status: 200, &response)
    @stubs.public_send(method, path) do |env|
      assert_equal "api.mch.weixin.qq.com", env.url.host
      assert_equal "https", env.url.scheme
      if version == "v2"
        fields = Hash.from_xml(env.body).fetch("xml")
        assert_equal @merchant_id, fields.fetch("mch_id")
        assert_equal @mini_program.appid, fields.fetch("appid")
        assert_equal "HMAC-SHA256", fields.fetch("sign_type")
        assert_equal v2_signature(fields), fields.fetch("sign")
        if path == "/secapi/pay/refund"
          assert_equal @certificate.to_der, env.ssl.client_cert.to_der
          assert @certificate.check_private_key(env.ssl.client_key)
        end
        [ status, { "Content-Type" => "text/xml" }, signed_xml(response.call(fields)) ]
      else
        scheme, attributes = env.request_headers.fetch("Authorization").split(" ", 2)
        assert_equal "WECHATPAY2-SHA256-RSA2048", scheme
        auth = attributes.scan(/(\w+)="([^"]+)"/).to_h
        assert_equal @merchant_id, auth.fetch("mchid")
        assert_equal @certificate.serial.to_s(16).upcase, auth.fetch("serial_no")
        message = [ method.to_s.upcase, env.url.request_uri, auth.fetch("timestamp"), auth.fetch("nonce_str"), env.body.to_s, "" ].join("\n")
        assert @certificate.public_key.verify("SHA256", Base64.strict_decode64(auth.fetch("signature")), message)
        data = response.call(env.body.present? ? JSON.parse(env.body) : {})
        body = status == 204 ? "" : JSON.generate(data)
        [ status, v3_headers(body), body ]
      end
    end
  end
end
