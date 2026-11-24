require "base64"
require "openssl"

module Wechat
  class PaymentV3Client
    ORIGIN = "https://api.mch.weixin.qq.com"
    SCHEME = "WECHATPAY2-SHA256-RSA2048"
    GATEWAY_ERRORS = {
      "SIGN_ERROR" => [ 401, "请求签名错误，请核对商户证书序列号、私钥和服务器时间" ],
      "ORDER_NOT_EXIST" => [ 404, "订单不存在，请核对原商户号和原支付单号" ],
      "RESOURCE_NOT_EXISTS" => [ 404, "查询的记录不存在，请核对原单号" ]
    }.freeze
    SIGNATURE_HEADERS = %w[Wechatpay-Timestamp Wechatpay-Nonce Wechatpay-Serial Wechatpay-Signature Wechatpay-Signature-Type].freeze
    GATEWAY_VERIFICATION = {
      invalid: "回包验签失败，错误内容未经验证",
      verified: "验签通过",
      unsigned: "未经验证，请按原单号核实"
    }.freeze
    GATEWAY_MESSAGES = GATEWAY_ERRORS.to_h do |code, (status, reason)|
      [ code, GATEWAY_VERIFICATION.transform_values { |state| "HTTP #{status} · #{code} · #{reason}（#{state}）" }.freeze ]
    end.freeze

    def self.diagnostic_details(details)
      details = {} unless details.is_a?(Hash)
      reason = details["reason"]
      reason = nil unless GATEWAY_MESSAGES.each_value.any? { |messages| messages.value?(reason) }
      headers = details["headers_present"]
      { reason: reason, headers_present: headers.is_a?(Array) ? SIGNATURE_HEADERS & headers : [] }
    end

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
      result = refund_result(data)
      result[:acceptance_state] = result[:state]
      result[:state] = "PROCESSING" if result[:state] == "SUCCESS"
      result.except(:refunded_at)
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
      associated = resource["associated_data"]
      raise Payments::InvalidResult unless associated.nil? || associated.is_a?(String)
      cipher.auth_data = associated || ""
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

    def request_verification_id
      [ %w[verification_id verification_pem], WechatPaySettings::BACKUP ].each do |id_field, pem_field|
        pem = @config[pem_field]
        next unless pem
        if pem.start_with?("-----BEGIN CERTIFICATE-----")
          cert = OpenSSL::X509::Certificate.new(pem)
          next unless Time.current.between?(cert.not_before, cert.not_after)
        end
        return @config.fetch(id_field)
      end
      raise WechatPaySettings::Invalid, "微信验签材料已失效，请更新「微信支付」主用或备用材料"
    end

    def verify!(body, headers)
      timestamp, nonce, serial, signature = %w[Timestamp Nonce Serial Signature].map { |name| headers["Wechatpay-#{name}"].to_s }
      unless timestamp.match?(/\A\d{1,12}\z/) && (Time.current.to_i - timestamp.to_i).abs <= 300 && nonce.present? &&
          headers["Wechatpay-Signature-Type"].in?([ nil, SCHEME ])
        raise Payments::InvalidResult
      end
      pem = if serial == @config.fetch("verification_id")
        @config.fetch("verification_pem")
      elsif serial.present? && serial == @config["backup_verification_id"]
        @config["backup_verification_pem"]
      end
      raise Payments::InvalidResult unless pem
      key = if pem.start_with?("-----BEGIN CERTIFICATE-----")
        cert = OpenSSL::X509::Certificate.new(pem)
        unless Time.at(timestamp.to_i).between?(cert.not_before, cert.not_after) && Time.current.between?(cert.not_before, cert.not_after)
          raise Payments::InvalidResult
        end
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
        "Wechatpay-Serial" => request_verification_id, "User-Agent" => "Booking-WeChat-Pay" }
      response = @connection.run_request(method, path, body, headers)
      raw = response.body.to_s
      response_error!(response, raw) unless response.success?
      verify!(raw, response.headers)
      raise Payments::InvalidResult unless response.status == status
      return json(raw) unless status == 204
      raise Payments::InvalidResult unless raw.empty?
      true
    rescue Faraday::Error
      raise Payments::Unavailable, cause: nil
    end

    def response_error!(response, raw)
      code = error_code(raw)
      expected_status = GATEWAY_ERRORS[code]&.first
      known_error = expected_status == response.status
      signed = response.headers["Wechatpay-Signature"].present?
      begin
        verify!(raw, response.headers) if signed
      rescue Payments::InvalidResult
        gateway_diagnostic(response, code, :invalid) if known_error
        raise
      end
      raise Payments::Unavailable if response.status >= 500 || response.status == 429
      message = gateway_diagnostic(response, code, signed ? :verified : :unsigned) if known_error
      raise Payments::Unavailable, message unless signed
      raise Payments::InvalidResult if code.nil? || (expected_status && !known_error)
      raise Payments::ChannelError.new(code, message)
    end

    def error_code(raw)
      return if raw.bytesize > 16.kilobytes
      data = JSON.parse(raw)
      data["code"] if data.is_a?(Hash) && data["code"].is_a?(String)
    rescue JSON::ParserError
      nil
    end

    def gateway_diagnostic(response, code, verification)
      message = GATEWAY_MESSAGES.fetch(code).fetch(verification)
      headers = SIGNATURE_HEADERS.select { |name| response.headers.key?(name) }
      begin
        Log.record!(source: "system", category: "payment", action: "wechat_pay.gateway_error", status: "failed",
          details: { reason: message, headers_present: headers })
      rescue ActiveRecord::ActiveRecordError
        Rails.logger.warn("微信支付诊断记录写入失败：#{message}")
      end
      message
    end

    def json(text)
      data = JSON.parse(text)
      raise Payments::InvalidResult unless data.is_a?(Hash)
      data
    rescue JSON::ParserError
      raise Payments::InvalidResult, cause: nil
    end

    def payment_result(data)
      data = optional_fields(data)
      amount = optional_fields(data.fetch("amount", {}))
      payer = optional_fields(data.fetch("payer", {}))
      { kind: :payment, state: data["trade_state"], merchant_id: data["mchid"], appid: data["appid"],
        payment_no: data["out_trade_no"], transaction_id: data["transaction_id"], trade_type: data["trade_type"],
        openid: payer["openid"], total_cents: amount["total"], currency: amount["currency"],
        paid_cents: amount["payer_total"], payer_currency: amount["payer_currency"],
        paid_at: timestamp(data["success_time"]) }
    rescue TypeError, ArgumentError
      raise Payments::InvalidResult, cause: nil
    end

    def refund_result(data, notification: false)
      # The authenticated domestic-refunds response omits mchid and appid. The
      # receiver binds it to the paid transaction ID and the original configuration.
      data = optional_fields(data)
      amount = optional_fields(data.fetch("amount"))
      { kind: :refund, state: data[notification ? "refund_status" : "status"], merchant_id: data.fetch("mchid", @merchant_id),
        appid: data["appid"], payment_no: data["out_trade_no"], transaction_id: data["transaction_id"],
        refund_no: data["out_refund_no"], refund_id: data["refund_id"], total_cents: amount["total"],
        refund_cents: amount["refund"], payer_refund_cents: amount["payer_refund"], paid_cents: amount["payer_total"],
        currency: amount.fetch("currency", ("CNY" if notification)),
        refunded_at: timestamp(data["success_time"]) }
    rescue TypeError, KeyError, ArgumentError
      raise Payments::InvalidResult, cause: nil
    end

    def optional_fields(data)
      raise Payments::InvalidResult unless data.is_a?(Hash)
      data.reject { |_, value| value.nil? || value == "" }
    end

    def timestamp(value)
      return if value.nil?
      DateTime.rfc3339(value).to_time
    end
  end
end
