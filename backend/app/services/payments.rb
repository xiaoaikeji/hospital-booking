require "ipaddr"

# Business records own payment contexts and refund reservations. The receiver's
# with_payment(number) locks the record, yields it and returns the block result
# after committing. A record exposes payment_context, refund(number) and apply!.
class Payments
  class Error < StandardError; end
  class InvalidResult < Error
    def initialize = super("微信支付结果未通过核对")
  end
  class Unavailable < Error
    def initialize = super("微信支付结果待核实，请按原单号查询")
  end
  class DeliveryError < Error; end
  class ChannelError < Error
    attr_reader :code

    def initialize(code)
      @code = code.to_s.match?(/\A[A-Z0-9_]{1,64}\z/) ? code : "UNKNOWN"
      super("微信支付返回 #{@code}")
    end
  end

  PAYMENT_STATES = %w[SUCCESS NOTPAY USERPAYING CLOSED REVOKED PAYERROR REFUND].freeze
  REFUND_STATES = %w[PROCESSING SUCCESS CLOSED ABNORMAL].freeze
  NUMBER = /\A[0-9]{20}\z/
  PROVIDER_NUMBER = /\A[0-9]{1,64}\z/

  def initialize(receiver: Rails.application.config.x.payments.receiver, http: HttpConnection)
    @receiver, @http = receiver, http
  end

  # Persist the returned server-side context before calling checkout, including on retry.
  def prepare(app:, identity:, payment_no:, amount_cents:)
    number!(payment_no)
    raise ArgumentError, "支付金额须为正整数分" unless amount_cents.is_a?(Integer) && amount_cents.positive?
    check_identity!(app, identity)
    WechatPaySettings.new.reserve!.merge("payment_no" => payment_no, "amount_cents" => amount_cents,
      "appid" => app.appid, "openid" => identity.openid)
  end

  # Save prepay_id and prepay_expires_at on the same business record. Only
  # payment_params go to the phone. Reopening the cashier re-signs the original prepay.
  def checkout(payment_no, app:, identity:, description: nil, client_ip: nil)
    payment = context(payment_no)
    check_identity!(app, identity)
    raise Error, "当前小程序或付款人与原单不符" unless payment["appid"] == app.appid && payment["openid"] == identity.openid
    raise Error, "支付单已结清或已关闭" if payment["transaction_id"].present? || payment["closed"]

    client, config = channel(payment)
    id, expiry = payment.values_at("prepay_id", "prepay_expires_at")
    unless id.present? && expiry && Time.iso8601(expiry) > Time.current
      raise ArgumentError, "请提供有效的支付说明" unless description.is_a?(String) && description.present? && description.bytesize <= 127
      if payment["version"] == "v2"
        raise ArgumentError, "请提供有效的终端 IP" unless client_ip.is_a?(String) && !client_ip.include?("/") && IPAddr.new(client_ip)
      end
      expiry = (Time.current + 2.hours).iso8601
      id = client.prepay(payment, description: description, client_ip: client_ip, notify_url: notify_url(config, payment, "payment"))
    end
    raise InvalidResult unless id.is_a?(String) && id.match?(/\A[A-Za-z0-9_-]{1,128}\z/)
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
    raise Unavailable
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
      result = verified
    end
    deliver(payment, result, refund_no: result[:refund_no])
  end

  private

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
          paid.is_a?(Integer) && paid.between?(1, payment.fetch("amount_cents")) && amount.is_a?(Integer) && amount.between?(1, paid)
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
    if !result[:total_cents].nil? || result[:kind] == :refund || result[:state] == "SUCCESS"
      unless result[:total_cents].is_a?(Integer) && result[:total_cents] == payment["amount_cents"] && result[:currency] == "CNY"
        raise InvalidResult
      end
    end
    result[:kind] == :refund ? verify_refund!(payment, result, refund) : verify_payment!(payment, result)
  end

  def verify_refund!(payment, result, refund)
    raise InvalidResult unless refund && result[:refund_no] == refund["refund_no"] && REFUND_STATES.include?(result[:state])
    raise InvalidResult unless provider_number?(result[:transaction_id]) && result[:transaction_id] == payment["transaction_id"]
    raise InvalidResult unless provider_number?(result[:refund_id])
    raise InvalidResult if refund["refund_id"].present? && refund["refund_id"] != result[:refund_id]

    amount, paid, cash = result[:refund_cents], payment["paid_cents"], result[:payer_refund_cents]
    raise InvalidResult unless amount.is_a?(Integer) && paid.is_a?(Integer) && amount.between?(1, paid) && amount == refund["refund_cents"]
    raise InvalidResult unless cash.nil? || (cash.is_a?(Integer) && cash.between?(0, amount))
  end

  def verify_payment!(payment, result)
    raise InvalidResult unless PAYMENT_STATES.include?(result[:state])
    raise InvalidResult if result[:openid] && result[:openid] != payment["openid"]
    raise InvalidResult if result[:trade_type] && result[:trade_type] != "JSAPI"
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
