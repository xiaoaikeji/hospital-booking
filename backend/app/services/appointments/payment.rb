module Appointments
  class Payment
    def initialize(appointment, source:, actor: nil, request: nil)
      @appointment = appointment
      @audit = { source: source, actor: actor, request: request }
      @payments = Payments.new(receiver: PaymentReceiver.new(**@audit))
    end

    def checkout(app:, identity:, client_ip:)
      check_payable!
      result = @payments.checkout(@appointment.payment_no, app: app, identity: identity, client_ip: client_ip,
        description: "预约挂号")
      @appointment.reload
      check_payable!
      result.fetch("payment_params")
    end

    def request_cancel!
      @appointment.with_lock do
        if @appointment.pending_payment?
          start_closing!("patient_requested")
        elsif @appointment.payment_status != "closed"
          raise Appointment::InvalidOperation, "支付状态已变化，请查看预约详情办理退号"
        end
      end
    end

    def reconcile!
      action = @appointment.with_lock do
        next unless @appointment.pending_payment?

        if @appointment.payment_closing?
          start_closing!("expired")
          if @appointment.payment_data["prepay_attempted"] == false
            PaymentReceiver::Order.new(@appointment, @audit).close_unpaid!("NOT_CREATED")
            next
          end
          :close
        elsif @appointment.payment_data["prepay_attempted"]
          :query
        end
      end
      @payments.public_send(action, @appointment.payment_no) if action
    rescue Payments::ChannelError => error
      return if reconcile_missing_order!(error)

      mark_unknown!
    rescue Payments::Error, WechatPaySettings::Invalid
      mark_unknown!
    ensure
      @appointment.reload
    end

    private

    def check_payable!
      unless @appointment.pending_payment? && !@appointment.payment_closing? && !@appointment.payment_checking?
        raise Appointment::InvalidOperation, "请查看当前预约的支付结果"
      end
    end

    def start_closing!(reason)
      return if @appointment.payment_cancel_requested_at?

      @appointment.update!(payment_cancel_requested_at: Time.current)
      @appointment.record_event!("payment_close_requested", **@audit, details: { reason: reason })
    end

    def reconcile_missing_order!(error)
      expected = @appointment.payment_data["version"] == "v2" ? "ORDERNOTEXIST" : "ORDER_NOT_EXIST"
      return false unless error.code == expected

      @appointment.with_lock do
        next true unless @appointment.pending_payment?
        next false if @appointment.payment_data["prepay_id"].present?

        if @appointment.payment_closing?
          # No payment parameters were issued. A late prepay cannot issue any
          # after we persist the close intent under the same appointment lock.
          PaymentReceiver::Order.new(@appointment, @audit).close_unpaid!("NOT_CREATED")
        else
          store_state!("NOTPAY")
        end
        true
      end
    end

    def mark_unknown!
      @appointment.with_lock { store_state!("UNKNOWN") if @appointment.pending_payment? }
    end

    def store_state!(state)
      return if @appointment.payment_data["trade_state"] == state

      @appointment.update!(payment_data: @appointment.payment_data.merge("trade_state" => state))
    end
  end
end
