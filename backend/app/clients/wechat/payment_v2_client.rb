require "base64"
require "openssl"

module Wechat
  class PaymentV2Client
    ORIGIN = "https://api.mch.weixin.qq.com"
    SIGN_TYPE = "HMAC-SHA256"

    def initialize(config, http: HttpConnection)
      @config, @http = config, http
    end

    def prepay(payment, description:, client_ip:, notify_url:)
      response = request("/pay/unifiedorder", payment, body: description, spbill_create_ip: client_ip, notify_url: notify_url,
        openid: payment.fetch("openid"), out_trade_no: payment.fetch("payment_no"), total_fee: payment.fetch("amount_cents"),
        fee_type: "CNY", trade_type: "JSAPI")
      raise Payments::InvalidResult unless response["trade_type"] == "JSAPI"
      response["prepay_id"]
    end

    def checkout_params(appid, prepay_id)
      fields = { "appId" => appid, "timeStamp" => Time.current.to_i.to_s, "nonceStr" => SecureRandom.hex(16),
        "package" => "prepay_id=#{prepay_id}", "signType" => SIGN_TYPE }
      fields.except("appId").merge("paySign" => sign(fields))
    end

    def query(payment)
      data = request("/pay/orderquery", payment, out_trade_no: payment.fetch("payment_no"))
      payment_result(data, data["trade_state"])
    end

    def close(payment)
      request("/pay/closeorder", payment, out_trade_no: payment.fetch("payment_no"))
    end

    def refund(payment, refund, notify_url:)
      data = request("/secapi/pay/refund", payment, tls: true, out_trade_no: payment.fetch("payment_no"),
        out_refund_no: refund.fetch("refund_no"), total_fee: payment.fetch("amount_cents"), refund_fee: refund.fetch("refund_cents"),
        refund_fee_type: "CNY", notify_url: notify_url)
      refund_result(data, "PROCESSING")
    end

    def query_refund(payment, refund_no)
      data = request("/pay/refundquery", payment, out_refund_no: refund_no)
      count = cents(data["refund_count"])
      raise Payments::InvalidResult unless count&.between?(1, 10)
      index = (0...count).select { |i| data["out_refund_no_#{i}"] == refund_no }.sole
      refund_result(data, data["refund_status_#{index}"], suffix: "_#{index}")
    rescue Enumerable::SoleItemExpectedError
      raise Payments::InvalidResult
    end

    def notification(body, headers:, kind:)
      data = parse(body)
      raise Payments::InvalidResult unless data["return_code"] == "SUCCESS" && data["mch_id"] == @config.fetch("merchant_id")
      if kind == "payment"
        verify!(data)
        raise Payments::InvalidResult unless data["result_code"] == "SUCCESS" && data.fetch("trade_state", "SUCCESS") == "SUCCESS"
        payment_result(data, "SUCCESS")
      else
        # V2 sends an unsigned envelope and AES-ECB ciphertext. A signed refund query
        # independently confirms this hint before the business receives a refund.
        cipher = OpenSSL::Cipher.new("aes-256-ecb").decrypt
        cipher.key = Digest::MD5.hexdigest(@config.fetch("v2_api_key"))
        plaintext = cipher.update(Base64.strict_decode64(data.fetch("req_info"))) + cipher.final
        detail = parse(plaintext, root: "root").merge(data.slice("appid", "mch_id"))
        refund_result(detail, detail["refund_status"])
      end
    rescue OpenSSL::OpenSSLError, ArgumentError, KeyError
      raise Payments::InvalidResult, cause: nil
    end

    private

    def sign(fields)
      pairs = fields.except("sign").reject { |_name, value| value.nil? || value == "" }.sort.map { |name, value| "#{name}=#{value}" }
      key = @config.fetch("v2_api_key")
      OpenSSL::HMAC.hexdigest("SHA256", key, (pairs << "key=#{key}").join("&")).upcase
    end

    def verify!(data)
      unless data.fetch("sign_type", SIGN_TYPE) == SIGN_TYPE && ActiveSupport::SecurityUtils.secure_compare(sign(data), data["sign"].to_s)
        raise Payments::InvalidResult
      end
    end

    def parse(xml, root: "xml")
      doc = Nokogiri::XML(xml) { |options| options.strict.nonet }
      raise Payments::InvalidResult if doc.internal_subset || doc.external_subset || doc.root&.name != root
      doc.root.element_children.each_with_object({}) do |child, fields|
        raise Payments::InvalidResult if fields.key?(child.name) || child.element_children.any?
        fields[child.name] = child.text
      end
    rescue Nokogiri::XML::SyntaxError
      raise Payments::InvalidResult, cause: nil
    end

    def request(path, payment, tls: false, **params)
      fields = params.stringify_keys.merge("appid" => payment.fetch("appid"), "mch_id" => @config.fetch("merchant_id"),
        "nonce_str" => SecureRandom.hex(16), "sign_type" => SIGN_TYPE)
      fields["sign"] = sign(fields)
      xml = Nokogiri::XML::Builder.new { |b| b.xml { fields.each { |name, value| b.send(name, value.to_s) } } }.to_xml
      ssl = if tls
        { client_cert: OpenSSL::X509::Certificate.new(@config.fetch("v2_certificate")),
          client_key: OpenSSL::PKey::RSA.new(@config.fetch("v2_private_key"), "") }
      else
        {}
      end
      response = @http.build(ORIGIN, ssl: ssl).post(path, xml, "Content-Type" => "text/xml; charset=utf-8")
      raise Payments::Unavailable unless response.status == 200
      data = parse(response.body)
      raise Payments::Unavailable unless data["return_code"] == "SUCCESS"
      verify!(data)
      raise Payments::InvalidResult unless data["appid"] == fields["appid"] && data["mch_id"] == fields["mch_id"]
      unless data["result_code"] == "SUCCESS"
        raise Payments::Unavailable if data["err_code"] == "SYSTEMERROR"
        raise Payments::ChannelError, data["err_code"]
      end
      data
    rescue Faraday::Error
      raise Payments::Unavailable, cause: nil
    end

    def cents(value)
      return if value.nil?
      raise Payments::InvalidResult unless value.match?(/\A\d{1,12}\z/)
      value.to_i
    end

    def payment_result(data, state)
      paid_at = Time.find_zone!("Asia/Shanghai").strptime(data["time_end"], "%Y%m%d%H%M%S") if data["time_end"].present?
      { kind: :payment, state: state, merchant_id: data["mch_id"], appid: data["appid"], payment_no: data["out_trade_no"],
        transaction_id: data["transaction_id"], total_cents: cents(data["total_fee"]), currency: data.fetch("fee_type", "CNY"),
        paid_cents: cents(data["cash_fee"]), payer_currency: data.fetch("cash_fee_type", "CNY"), paid_at: paid_at,
        openid: data["openid"], trade_type: data["trade_type"] }
    rescue ArgumentError
      raise Payments::InvalidResult, cause: nil
    end

    def refund_result(data, state, suffix: "")
      timestamp = data["refund_success_time#{suffix}"] || data["success_time"]
      refunded_at = Time.find_zone!("Asia/Shanghai").strptime(timestamp, "%Y-%m-%d %H:%M:%S") if timestamp.present?
      { kind: :refund, state: { "REFUNDCLOSE" => "CLOSED", "CHANGE" => "ABNORMAL" }.fetch(state, state),
        merchant_id: data["mch_id"], appid: data["appid"], payment_no: data["out_trade_no"], transaction_id: data["transaction_id"],
        total_cents: cents(data["total_fee"]), refund_no: data["out_refund_no#{suffix}"], refund_id: data["refund_id#{suffix}"],
        refund_cents: cents(data["refund_fee#{suffix}"]), payer_refund_cents: cents(data["cash_refund_fee#{suffix}"]),
        currency: data.fetch("fee_type", "CNY"), refunded_at: refunded_at }
    rescue ArgumentError
      raise Payments::InvalidResult, cause: nil
    end
  end
end
