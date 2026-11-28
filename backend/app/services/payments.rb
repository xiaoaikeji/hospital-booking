require "ipaddr"

# Business records own payment contexts and refund reservations. The receiver's
# with_payment(number) locks the record, yields it and returns the block result
# after committing. The record persists checkout parameters and refund attempts
# before network I/O, and applies verified results inside the same lock.
class Payments
  class Error < StandardError; end
  class InvalidResult < Error
    def initialize = super("微信支付结果未通过核对")
  end
  class Unavailable < Error
    def initialize(message = nil) = super(message || "微信支付结果待核实，请按原单号查询")
  end
  class CheckoutInFlight < Unavailable; end
  class RefundNotFound < Unavailable; end
  class DeliveryError < Error; end
  class ChannelError < Error
    attr_reader :code

    def initialize(code, message = nil)
      @code = code.to_s.match?(/\A[A-Z0-9_]{1,64}\z/) ? code : "UNKNOWN"
      super(message || "微信支付返回 #{@code}")
    end
  end

  class PrepayRejected < ChannelError; end

  IN_FLIGHT_OUTCOMES = %w[in_flight in_flight_order_found].freeze
  PAYMENT_STATES = %w[SUCCESS NOTPAY USERPAYING CLOSED REVOKED PAYERROR REFUND].freeze
  REFUND_STATES = %w[PROCESSING SUCCESS CLOSED ABNORMAL].freeze
  NUMBER = /\A[0-9]{20}\z/
  PROVIDER_NUMBER = /\A[0-9]{1,64}\z/
  PREPAY_MARGIN = 5.minutes

  def initialize(receiver: Rails.application.config.x.payments.receiver, http: HttpConnection)
    @receiver, @http = receiver, http
  end

  # Persist the returned server-side context before calling checkout, including on retry.
  def prepare(app:, identity:, payment_no:, amount_cents:)
    number!(payment_no)
    raise ArgumentError, "支付金额须为正整数分" unless amount_cents.is_a?(Integer) && amount_cents.positive?
    check_identity!(app, identity)
    WechatPaySettings.new.reserve!.merge("payment_no" => payment_no, "amount_cents" => amount_cents,
      "appid" => app.appid, "openid" => identity.openid, "prepay_attempted" => false)
  end

  # Commit the first request parameters before contacting WeChat. A missing attempt
  # marker on an older order means the result of its last request is unknown.
  def checkout(payment_no, app:, identity:, description: nil, client_ip: nil)
    payment = context(payment_no)
    check_identity!(app, identity)
    raise Error, "当前小程序或付款人与原单不符" unless payment["appid"] == app.appid && payment["openid"] == identity.openid
    check_payable!(payment)
    raise CheckoutInFlight if IN_FLIGHT_OUTCOMES.include?(payment["prepay_outcome"])

    client, config = channel(payment)
    id, expiry = payment.values_at("prepay_id", "prepay_expires_at")
    deadline = Time.iso8601(expiry) if id.present? && expiry.present?
    unless reusable_prepay?(payment, deadline)
      args, attempt, can_rule_out_order = with_payment(payment_no) do |order|
        current = order.payment_context
        check_payable!(current)
        raise CheckoutInFlight if IN_FLIGHT_OUTCOMES.include?(current["prepay_outcome"])
        raise Unavailable unless current["prepay_attempt"] == payment["prepay_attempt"]
        original = current["checkout_request"] || checkout_request(payment, description, client_ip)
        attempt = SecureRandom.uuid
        # A later rejection can't rule out an order from an earlier ambiguous attempt.
        can_rule_out_order = current["prepay_id"].blank? &&
          (current["prepay_attempted"] == false || current["prepay_outcome"] == "rejected")
        unless order.save_checkout!({ "checkout_request" => original, "prepay_attempted" => true,
            "prepay_attempt" => attempt, "prepay_outcome" => "in_flight" }) == true
          raise DeliveryError, "预支付请求写入失败"
        end
        [ original, attempt, can_rule_out_order ]
      end
      new_expiry = 2.hours.from_now.iso8601
      begin
        fresh = client.prepay(payment, description: args.fetch("description"), client_ip: args["client_ip"], notify_url: notify_url(config, payment, "payment"))
        validate_prepay!(fresh)
        # A repeated ID keeps its original lifetime. Finish this attempt even when it has expired.
        raise Unavailable if fresh == id && !deadline&.future?
      rescue Error, WechatPaySettings::Invalid => error
        record_checkout_failure!(payment_no, attempt, rejected: can_rule_out_order && error.is_a?(PrepayRejected))
        raise
      end
      expiry = new_expiry unless fresh == id
      id = fresh
      with_payment(payment_no) do |order|
        current = order.payment_context
        raise Unavailable if current["prepay_attempt"] != attempt || current["closed"] || current["transaction_id"].present?
        attributes = { "prepay_id" => id, "prepay_expires_at" => expiry, "prepay_outcome" => "accepted" }
        attributes["trade_state"] = "NOTPAY" if current["trade_state"] == "UNKNOWN"
        raise DeliveryError, "预支付凭证写入失败" unless order.save_checkout!(attributes) == true
        true
      end
    end
    check_payable!(context(payment_no))
    validate_prepay!(id)
    { "prepay_id" => id, "prepay_expires_at" => expiry, "payment_params" => client.checkout_params(app.appid, id) }
  end

  def query(payment_no)
    payment = context(payment_no)
    client, = channel(payment)
    deliver(payment, client.query(payment))
  end

  def close(payment_no)
    result = query(payment_no)
    return result unless result[:state] == "NOTPAY"
    payment = context(payment_no)
    return query(payment_no) if payment["closed"] || payment["transaction_id"].present?
    client, = channel(payment)
    begin
      client.close(payment)
    rescue ChannelError => error
      raise unless %w[ORDERPAID ORDER_PAID ORDERCLOSED ORDER_CLOSED].include?(error.code)
    rescue Unavailable
      # The close may have reached WeChat. Query the same number in either case.
    end
    query(payment_no)
  end

  # The business has already committed the refund number, amount and reservation.
  # No network request takes place while holding a business record lock.
  def refund(payment_no, refund_no:)
    payment, refund = refund_context(payment_no, refund_no)
    return query_refund(payment_no, refund_no: refund_no) if refund["refund_id"].present?
    client, config = channel(payment)
    retrying = with_payment(payment_no) do |order|
      record = order.refund(refund_no)
      raise InvalidResult unless record && record["refund_cents"] == refund["refund_cents"]
      previous = record["attempted"] || record["submitted_at"].present? || record["refund_id"].present?
      WechatPaySettings.refund_tls!(config) if !previous && payment["version"] == "v2"
      raise DeliveryError, "退款申请写入失败" unless order.mark_refund_attempted!(refund_no) == true
      previous ? :lookup : :submit
    end
    if retrying == :lookup
      begin
        return query_refund(payment_no, refund_no: refund_no)
      rescue RefundNotFound
        # Only a verified not-found permits another attempt, with the same reservation.
      end
    end
    begin
      result = client.refund(payment, refund, notify_url: notify_url(config, payment, "refund"))
    rescue Unavailable
      return query_refund(payment_no, refund_no: refund_no)
    end
    deliver(payment, result, refund_no: refund_no)
  end

  def query_refund(payment_no, refund_no:)
    payment, = refund_context(payment_no, refund_no)
    client, = channel(payment)
    deliver(payment, client.query_refund(payment, refund_no), refund_no: refund_no)
  rescue ChannelError => error
    raise unless %w[REFUNDNOTEXIST RESOURCE_NOT_EXISTS].include?(error.code)
    # Absence immediately after submission does not release the business reservation.
    raise RefundNotFound
  end

  def receive(version:, config_ref:, kind:, body:, headers:)
    config = WechatPaySettings.fetch!(config_ref)
    raise InvalidResult unless config["version"] == version && %w[payment refund].include?(kind)
    client = client_for(config)
    result = client.notification(body, headers: headers, kind: kind)
    payment = context(number!(result[:payment_no]))
    raise InvalidResult unless payment["config_ref"] == config_ref && payment["version"] == version
    if version == "v2" && kind == "refund"
      refund_no = number!(result[:refund_no])
      _, refund = refund_context(payment.fetch("payment_no"), refund_no)
      verify!(payment, result, refund: refund)
      verified = client.query_refund(payment, refund_no)
      keys = %i[state appid merchant_id payment_no transaction_id total_cents refund_no refund_id refund_cents]
      raise InvalidResult unless verified.slice(*keys) == result.slice(*keys)
      if result[:payer_refund_cents] && verified[:payer_refund_cents] && verified[:payer_refund_cents] != result[:payer_refund_cents]
        raise InvalidResult
      end
      # Bind the decrypted notice to this exact refund and state before filling a
      # field omitted by the signed query. Conflicting or previously changed cash fails closed.
      verified[:payer_refund_cents] ||= result[:payer_refund_cents]
      result = verified
    end
    deliver(payment, result, refund_no: result[:refund_no])
  end

  private

  def checkout_request(payment, description, client_ip)
    raise ArgumentError, "请提供有效的原支付说明" unless description.is_a?(String) && description.present? && description.bytesize <= 127
    if payment["version"] == "v2"
      raise ArgumentError, "请提供有效的原终端 IP" unless client_ip.is_a?(String) && !client_ip.include?("/") && IPAddr.new(client_ip)
    end
    { "description" => description, "client_ip" => client_ip }
  end

  def record_checkout_failure!(payment_no, attempt, rejected:)
    with_payment(payment_no) do |order|
      current = order.payment_context
      next true unless current["prepay_attempt"] == attempt && IN_FLIGHT_OUTCOMES.include?(current["prepay_outcome"])
      next true if current["closed"] || current["transaction_id"].present?

      if current["prepay_outcome"] == "in_flight_order_found"
        next order.save_checkout!("prepay_outcome" => "accepted")
      end

      order.save_checkout!("prepay_outcome" => (rejected ? "rejected" : "unknown"),
        "trade_state" => (rejected ? "NOTPAY" : "UNKNOWN"))
    end
  end

  def validate_prepay!(id)
    raise InvalidResult unless id.is_a?(String) && id.match?(/\A[A-Za-z0-9_-]{1,128}\z/)
  end

  def check_payable!(payment)
    raise Error, "支付单已结清或已关闭" if payment["transaction_id"].present? || payment["closed"]
    raise Error, "预约正在关闭，请查看预约结果" if payment["closing"]
    raise Error, "已超过预约付款时间" if payment["expires_at"] && Time.iso8601(payment["expires_at"]) <= Time.current
  end

  def reusable_prepay?(payment, deadline)
    return true if deadline && deadline > PREPAY_MARGIN.from_now
    return false if payment["prepay_attempted"] == false && payment["prepay_id"].blank?
    return false if payment["prepay_outcome"] == "rejected"

    state = query(payment.fetch("payment_no"))[:state]
    if state == "NOTPAY"
      current = context(payment.fetch("payment_no"))
      check_payable!(current)
      raise Unavailable unless current["prepay_attempt"] == payment["prepay_attempt"]
      return deadline&.future?
    end
    raise Unavailable if state == "USERPAYING"
    raise Error, "原支付单状态为 #{state}，无法继续调起收银台"
  rescue ChannelError => error
    missing = payment.fetch("version") == "v2" ? "ORDERNOTEXIST" : "ORDER_NOT_EXIST"
    raise unless error.code == missing
    false
  end

  def with_payment(number, &block)
    number!(number)
    raise DeliveryError, "支付业务接收方尚未配置" unless @receiver
    value = @receiver.with_payment(number, &block)
    raise DeliveryError, "支付业务未确认处理" unless value
    value
  end

  def context(number)
    with_payment(number) { |order| order.payment_context.deep_dup }.tap do |payment|
      raise InvalidResult unless payment["payment_no"] == number
    end
  end

  def refund_context(number, refund_no)
    number!(refund_no)
    with_payment(number) do |order|
      payment = order.payment_context
      refund = order.refund(refund_no)
      raise DeliveryError, "找不到原退款记录" unless refund && refund["refund_no"] == refund_no
      amount, paid = refund["refund_cents"], payment["paid_cents"]
      unless payment["payment_no"] == number && provider_number?(payment["transaction_id"]) &&
          paid.is_a?(Integer) && paid.between?(0, payment.fetch("amount_cents")) && amount.is_a?(Integer) && amount.between?(1, payment.fetch("amount_cents"))
        raise InvalidResult
      end
      [ payment.deep_dup, refund.deep_dup ]
    end
  end

  def check_identity!(app, identity)
    unless app&.code_capable? && app.accessible? && identity&.persisted? && identity.provider == app.provider &&
        identity.appid == app.appid && identity.openid.present? && identity.last_sign_in_at
      raise Error, "请在当前微信小程序登录后支付"
    end
    MiniProgramLogin.check_account!(identity, identity.user)
  end

  def channel(payment)
    config = WechatPaySettings.fetch!(payment.fetch("config_ref"))
    raise InvalidResult unless config["version"] == payment["version"] && config["merchant_id"] == payment["merchant_id"]
    [ client_for(config), config ]
  end

  def client_for(config)
    case config.fetch("version")
    when "v2" then Wechat::PaymentV2Client.new(config, http: @http)
    when "v3" then Wechat::PaymentV3Client.new(config, http: @http)
    else raise InvalidResult
    end
  end

  def notify_url(config, payment, kind)
    path = Rails.application.routes.url_helpers.api_wechat_payment_notification_path(
      version: payment.fetch("version"), config_ref: payment.fetch("config_ref"), kind: kind)
    config.fetch("notify_origin") + path
  end

  def number!(value)
    raise ArgumentError, "业务支付或退款单号须为 20 位数字" unless value.is_a?(String) && NUMBER.match?(value)
    value
  end

  def provider_number?(value) = value.is_a?(String) && PROVIDER_NUMBER.match?(value)

  def deliver(expected, result, refund_no: nil)
    raise InvalidResult unless result[:payment_no] == expected["payment_no"] && result[:refund_no] == refund_no
    committed = with_payment(expected.fetch("payment_no")) do |order|
      payment = order.payment_context
      raise InvalidResult unless payment["config_ref"] == expected["config_ref"] && payment["version"] == expected["version"]
      refund = order.refund(refund_no) if refund_no
      raise DeliveryError, "找不到原退款记录" if refund_no && !refund
      verify!(payment, result, refund: refund)
      result[:payer_refund_cents] = refund["payer_refund_cents"] if refund && result[:payer_refund_cents].nil?
      # V3 refunds identify the app by the verified original paid transaction.
      result[:appid] ||= payment.fetch("appid")
      raise DeliveryError, "支付业务写入失败" unless order.apply!(result) == true
      result
    end
    raise DeliveryError, "支付业务写入失败" unless committed.equal?(result)
    result
  end

  def verify!(payment, result, refund:)
    missing_appid = payment["version"] == "v3" && result[:kind] == :refund && result[:appid].nil?
    unless result[:merchant_id] == payment["merchant_id"] && result[:payment_no] == payment["payment_no"] &&
        (missing_appid || result[:appid] == payment["appid"])
      raise InvalidResult
    end
    required = result[:kind] == :refund || result[:state] == "SUCCESS"
    if required || !result[:total_cents].nil?
      raise InvalidResult unless result[:total_cents].is_a?(Integer) && result[:total_cents] == payment["amount_cents"]
      raise InvalidResult if (required || result[:currency]) && result[:currency] != "CNY"
    end
    result[:kind] == :refund ? verify_refund!(payment, result, refund) : verify_payment!(payment, result)
  end

  def verify_refund!(payment, result, refund)
    raise InvalidResult unless refund && result[:refund_no] == refund["refund_no"] && REFUND_STATES.include?(result[:state])
    raise InvalidResult unless provider_number?(result[:transaction_id]) && result[:transaction_id] == payment["transaction_id"]
    raise InvalidResult unless provider_number?(result[:refund_id])
    raise InvalidResult if refund["refund_id"].present? && refund["refund_id"] != result[:refund_id]

    amount, paid, cash = result[:refund_cents], payment["paid_cents"], result[:payer_refund_cents]
    raise InvalidResult unless amount.is_a?(Integer) && paid.is_a?(Integer) && amount.between?(1, payment.fetch("amount_cents")) && amount == refund["refund_cents"]
    raise InvalidResult unless result[:paid_cents].nil? || (result[:paid_cents].is_a?(Integer) && result[:paid_cents] == paid)
    raise InvalidResult unless cash.nil? || (cash.is_a?(Integer) && cash.between?(0, [ amount, paid ].min))
    known = refund["payer_refund_cents"]
    raise InvalidResult if !known.nil? && !cash.nil? && known != cash
  end

  def verify_payment!(payment, result)
    raise InvalidResult unless PAYMENT_STATES.include?(result[:state])
    raise InvalidResult if !result[:transaction_id].nil? && !provider_number?(result[:transaction_id])
    raise InvalidResult if !result[:paid_cents].nil? && !(result[:paid_cents].is_a?(Integer) && result[:paid_cents].between?(0, payment.fetch("amount_cents")))
    raise InvalidResult if [ result[:currency], result[:payer_currency] ].compact.any? { |code| code != "CNY" }
    raise InvalidResult if !result[:openid].nil? && result[:openid] != payment["openid"]
    raise InvalidResult if !result[:trade_type].nil? && result[:trade_type] != "JSAPI"
    if result[:transaction_id] && payment["transaction_id"].present? && result[:transaction_id] != payment["transaction_id"]
      raise InvalidResult
    end
    return unless result[:state] == "SUCCESS"
    raise InvalidResult unless provider_number?(result[:transaction_id]) && result[:trade_type] == "JSAPI" && result[:openid] == payment["openid"]
    paid = result[:paid_cents]
    raise InvalidResult unless result[:paid_at] && result[:payer_currency] == "CNY" && paid.is_a?(Integer) && paid.between?(0, payment.fetch("amount_cents"))
    raise InvalidResult if payment["transaction_id"].present? && !payment["paid_cents"].nil? && paid != payment["paid_cents"]
  end
end
