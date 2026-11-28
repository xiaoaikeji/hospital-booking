module Appointments
  class Payment
    CANCEL_REASON_LIMIT = 500

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

    def request_cancel!(reason: nil)
      staff_reason = checked_staff_reason!(reason) if @audit[:source] == "admin"
      @appointment.with_lock do
        if @appointment.pending_payment?
          next start_closing!(staff_reason ? "工作人员申请取消" : "patient_requested", staff_reason:)
        end
        next if @appointment.payment_status == "closed"
        next if staff_reason && @appointment.status == "confirmed" && @appointment.payment_status == "paid"

        raise Appointment::InvalidOperation, "支付状态已变化，请查看预约详情办理退号"
      end
    end

    def reconcile!
      action, attempt, outcome = @appointment.with_lock do
        next unless @appointment.pending_payment?

        if @appointment.payment_closing?
          start_closing!("expired")
          if @appointment.payment_data["prepay_attempted"] == false && @appointment.payment_data["prepay_id"].blank?
            PaymentReceiver::Order.new(@appointment, @audit).close_unpaid!("NOT_CREATED")
            next
          end
          [ :close, *@appointment.payment_data.values_at("prepay_attempt", "prepay_outcome") ]
        elsif @appointment.payment_data["prepay_attempted"]
          [ :query, *@appointment.payment_data.values_at("prepay_attempt", "prepay_outcome") ]
        end
      end
      @payments.public_send(action, @appointment.payment_no) if action
    rescue Payments::ChannelError => error
      reconcile_missing_order!(error, attempt, outcome) || mark_unknown!(attempt, outcome)
    rescue Payments::Error, WechatPaySettings::Invalid
      mark_unknown!(attempt, outcome)
    ensure
      @appointment.reload
    end

    private

    def check_payable!
      unless @appointment.pending_payment? && !@appointment.payment_closing? && !@appointment.payment_checking?
        raise Appointment::InvalidOperation, "请查看当前预约的支付结果"
      end
    end

    def checked_staff_reason!(reason)
      admin = @audit[:actor]
      unless admin.is_a?(Admin) && admin.enabled? && admin.maintain_booking_directory?
        raise Appointment::InvalidOperation, "没有办理权限"
      end
      note = reason.to_s.strip.presence
      raise Appointment::InvalidOperation, "请填写取消原因" unless note
      raise Appointment::InvalidOperation, "取消原因最多 #{CANCEL_REASON_LIMIT} 字" if note.length > CANCEL_REASON_LIMIT

      note
    end

    def start_closing!(reason, staff_reason: nil)
      return if @appointment.payment_cancel_requested_at?

      attributes = { payment_cancel_requested_at: Time.current }
      if staff_reason
        attributes[:payment_data] = @appointment.payment_data.merge(
          "staff_cancellation" => { "admin_id" => @audit[:actor].id, "reason" => staff_reason }
        )
      end
      @appointment.update!(**attributes)
      @appointment.record_event!("payment_close_requested", **@audit, details: { reason: reason },
        status: staff_reason ? "started" : "success")
    end

    def reconcile_missing_order!(error, attempt, outcome)
      expected = @appointment.payment_data["version"] == "v2" ? "ORDERNOTEXIST" : "ORDER_NOT_EXIST"
      return false unless error.code == expected

      @appointment.with_lock do
        next true unless @appointment.pending_payment?
        next true unless current_attempt?(attempt, outcome)
        next false unless outcome == "rejected" && @appointment.payment_data["prepay_id"].blank?

        if @appointment.payment_closing?
          PaymentReceiver::Order.new(@appointment, @audit).close_unpaid!("ORDER_NOT_CREATED")
        else
          store_state!("NOTPAY")
        end
        true
      end
    end

    def mark_unknown!(attempt, outcome)
      @appointment.with_lock do
        if @appointment.pending_payment? && current_attempt?(attempt, outcome) &&
            (outcome != "rejected" || @appointment.payment_closing?)
          store_state!("UNKNOWN")
        end
      end
    end

    def current_attempt?(attempt, outcome)
      @appointment.payment_data.values_at("prepay_attempt", "prepay_outcome") == [ attempt, outcome ]
    end

    def store_state!(state)
      return if @appointment.payment_data["trade_state"] == state

      @appointment.update!(payment_data: @appointment.payment_data.merge("trade_state" => state))
    end
  end
end
