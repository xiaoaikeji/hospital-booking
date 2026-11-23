require "base64"
require "openssl"

module Wechat
  class PaymentV3Client
    ORIGIN = "https://api.mch.weixin.qq.com"
    SCHEME = "WECHATPAY2-SHA256-RSA2048"

    def initialize(config, http: HttpConnection)
      @config = config
      @merchant_id = config.fetch("merchant_id")
      @connection = http.build(ORIGIN)
    end

    def prepay(payment, description:, client_ip:, notify_url:)
      data = request(:post, "/v3/pay/transactions/jsapi", {
        appid: payment.fetch("appid"), mchid: @merchant_id, description: description,
        out_trade_no: payment.fetch("payment_no"), notify_url: notify_url,
        amount: { total: payment.fetch("amount_cents"), currency: "CNY" }, payer: { openid: payment.fetch("openid") }
      })
      data["prepay_id"]
    end

    def checkout_params(appid, prepay_id)
      timestamp, nonce = Time.current.to_i.to_s, SecureRandom.hex(16)
      package = "prepay_id=#{prepay_id}"
      { "timeStamp" => timestamp, "nonceStr" => nonce, "package" => package, "signType" => "RSA",
        "paySign" => sign("#{appid}\n#{timestamp}\n#{nonce}\n#{package}\n") }
    end

    def query(payment)
      payment_result(request(:get, "/v3/pay/transactions/out-trade-no/#{payment.fetch("payment_no")}?mchid=#{@merchant_id}"))
    end

    def close(payment)
      request(:post, "/v3/pay/transactions/out-trade-no/#{payment.fetch("payment_no")}/close", { mchid: @merchant_id }, status: 204)
    end

    def refund(payment, refund, notify_url:)
      data = request(:post, "/v3/refund/domestic/refunds", {
        out_trade_no: payment.fetch("payment_no"), out_refund_no: refund.fetch("refund_no"), notify_url: notify_url,
        amount: { refund: refund.fetch("refund_cents"), total: payment.fetch("amount_cents"), currency: "CNY" }
      })
      raise Payments::InvalidResult unless Payments::REFUND_STATES.include?(data["status"])
      refund_result(data).merge(state: "PROCESSING")
    end

    def query_refund(payment, refund_no)
      refund_result(request(:get, "/v3/refund/domestic/refunds/#{refund_no}"))
    end

    def notification(body, headers:, kind:)
      verify!(body, headers)
      envelope = json(body)
      resource = envelope.fetch("resource")
      type = kind == "payment" ? "transaction" : "refund"
      unless resource.is_a?(Hash) && envelope["resource_type"] == "encrypt-resource" && resource["algorithm"] == "AEAD_AES_256_GCM" && resource["original_type"] == type
        raise Payments::InvalidResult
      end
      ciphertext = Base64.strict_decode64(resource.fetch("ciphertext"))
      raise Payments::InvalidResult unless ciphertext.bytesize > 16
      cipher = OpenSSL::Cipher.new("aes-256-gcm").decrypt
      cipher.key = @config.fetch("v3_api_key")
      cipher.iv = resource.fetch("nonce")
      cipher.auth_tag = ciphertext.byteslice(-16, 16)
      cipher.auth_data = resource.fetch("associated_data", "")
      data = json(cipher.update(ciphertext.byteslice(0...-16)) + cipher.final)
      raise Payments::InvalidResult unless data["mchid"] == @merchant_id
      if kind == "payment"
        raise Payments::InvalidResult unless envelope["event_type"] == "TRANSACTION.SUCCESS" && data["trade_state"] == "SUCCESS"
        payment_result(data)
      else
        state = data["refund_status"]
        raise Payments::InvalidResult unless %w[SUCCESS ABNORMAL CLOSED].include?(state) && envelope["event_type"] == "REFUND.#{state}"
        refund_result(data, notification: true)
      end
    rescue KeyError, ArgumentError, TypeError, OpenSSL::OpenSSLError
      raise Payments::InvalidResult, cause: nil
    end

    private

    def sign(message)
      @private_key ||= OpenSSL::PKey::RSA.new(@config.fetch("v3_private_key"), "")
      Base64.strict_encode64(@private_key.sign("SHA256", message))
    end

    def verify!(body, headers)
      timestamp, nonce, serial, signature = %w[Timestamp Nonce Serial Signature].map { |name| headers["Wechatpay-#{name}"].to_s }
      unless timestamp.match?(/\A\d{1,12}\z/) && (Time.current.to_i - timestamp.to_i).abs <= 300 && nonce.present? &&
          serial == @config.fetch("verification_id") && headers["Wechatpay-Signature-Type"].in?([ nil, SCHEME ])
        raise Payments::InvalidResult
      end
      pem = @config.fetch("verification_pem")
      key = if pem.start_with?("-----BEGIN CERTIFICATE-----")
        cert = OpenSSL::X509::Certificate.new(pem)
        raise Payments::InvalidResult unless Time.at(timestamp.to_i).between?(cert.not_before, cert.not_after)
        cert.public_key
      else
        OpenSSL::PKey::RSA.new(pem)
      end
      unless key.verify("SHA256", Base64.strict_decode64(signature), "#{timestamp}\n#{nonce}\n#{body}\n")
        raise Payments::InvalidResult
      end
    rescue ArgumentError, OpenSSL::OpenSSLError
      raise Payments::InvalidResult, cause: nil
    end

    def request(method, path, params = nil, status: 200)
      body = JSON.generate(params) if params
      timestamp, nonce = Time.current.to_i.to_s, SecureRandom.hex(16)
      signature = sign("#{method.to_s.upcase}\n#{path}\n#{timestamp}\n#{nonce}\n#{body}\n")
      authorization = %(#{SCHEME} mchid="#{@merchant_id}",nonce_str="#{nonce}",timestamp="#{timestamp}",serial_no="#{@config.fetch("merchant_serial")}",signature="#{signature}")
      headers = { "Authorization" => authorization, "Accept" => "application/json", "Content-Type" => "application/json",
        "Wechatpay-Serial" => @config.fetch("verification_id"), "User-Agent" => "Booking-WeChat-Pay" }
      response = @connection.run_request(method, path, body, headers)
      raw = response.body.to_s
      verify!(raw, response.headers)
      raise Payments::Unavailable if response.status >= 500 || response.status == 429
      raise Payments::ChannelError, json(raw)["code"] unless response.success?
      raise Payments::InvalidResult unless response.status == status
      return json(raw) unless status == 204
      raise Payments::InvalidResult unless raw.empty?
      true
    rescue Faraday::Error
      raise Payments::Unavailable, cause: nil
    end

    def json(text)
      data = JSON.parse(text)
      raise Payments::InvalidResult unless data.is_a?(Hash)
      data
    rescue JSON::ParserError
      raise Payments::InvalidResult, cause: nil
    end

    def payment_result(data)
      { kind: :payment, state: data["trade_state"], merchant_id: data["mchid"], appid: data["appid"],
        payment_no: data["out_trade_no"], transaction_id: data["transaction_id"], trade_type: data["trade_type"],
        openid: data.dig("payer", "openid"), total_cents: data.dig("amount", "total"), currency: data.dig("amount", "currency"),
        paid_cents: data.dig("amount", "payer_total"), payer_currency: data.dig("amount", "payer_currency"),
        paid_at: (Time.iso8601(data["success_time"]) if data["success_time"]) }
    rescue TypeError, ArgumentError
      raise Payments::InvalidResult, cause: nil
    end

    def refund_result(data, notification: false)
      # The authenticated domestic-refunds response omits mchid and appid. The
      # receiver binds it to the paid transaction ID and the original configuration.
      amount = data["amount"]
      raise Payments::InvalidResult unless amount.is_a?(Hash)
      { kind: :refund, state: data[notification ? "refund_status" : "status"], merchant_id: data.fetch("mchid", @merchant_id),
        appid: data["appid"], payment_no: data["out_trade_no"], transaction_id: data["transaction_id"],
        refund_no: data["out_refund_no"], refund_id: data["refund_id"], total_cents: amount["total"],
        refund_cents: amount["refund"], payer_refund_cents: amount["payer_refund"],
        currency: amount.fetch("currency", ("CNY" if notification)),
        refunded_at: (Time.iso8601(data["success_time"]) if data["success_time"]) }
    rescue TypeError, KeyError, ArgumentError
      raise Payments::InvalidResult, cause: nil
    end
  end
end
