module Appointments
  class PaymentReceiver
    def initialize(source:, actor: nil, request: nil)
      @audit = { source: source, actor: actor, request: request }
    end

    def with_payment(payment_no)
      Appointment.transaction do
        appointment = Appointment.lock.find_by(payment_no: payment_no, payment_channel: "wechat_jsapi")
        yield Order.new(appointment, @audit) if appointment
      end
    end

    class Order
      def initialize(appointment, audit)
        @appointment, @audit = appointment, audit
      end

      def payment_context
        @appointment.payment_data.merge(
          "payment_no" => @appointment.payment_no, "merchant_id" => @appointment.mch_id, "appid" => @appointment.payment_appid,
          "amount_cents" => @appointment.payable_amount_cents, "transaction_id" => @appointment.transaction_no,
          "paid_cents" => (@appointment.paid_amount_cents if @appointment.payment_status == "paid"),
          "closed" => @appointment.payment_status == "closed", "closing" => @appointment.payment_cancel_requested_at.present?,
          "starts_at" => @appointment.created_at.iso8601, "expires_at" => @appointment.payment_expires_at&.iso8601
        )
      end

      def save_checkout!(attributes)
        @appointment.update!(payment_data: @appointment.payment_data.merge(attributes))
        if attributes.key?("prepay_attempt")
          @appointment.record_event!("checkout", **@audit, details: { payment_no: @appointment.payment_no })
        end
        true
      end

      def close_unpaid!(state)
        return true unless @appointment.pending_payment?

        now = Time.current
        @appointment.update!(status: "cancelled", payment_status: "closed", cancelled_at: now, payment_closed_at: now,
          payment_data: @appointment.payment_data.merge("trade_state" => state))
        @appointment.record_event!("payment_closed", **@audit, details: { payment_no: @appointment.payment_no, channel_outcome: state })
        GroupNotice.publish("unpaid_cancelled", @appointment) if patient_requested_close?
        true
      end

      def refund(refund_no)
        item = @appointment.refund_items.find { |row| row["refund_no"] == refund_no }
        return unless item && item["amount_cents"].to_i.positive? && (item["attempted"] || item["status"] == "processing")

        item.slice("refund_no", "attempted", "submitted_at", "payer_refund_cents").merge(
          "refund_cents" => item.fetch("amount_cents"), "refund_id" => item["provider_refund_no"]
        )
      end

      def mark_refund_attempted!(refund_no)
        items = @appointment.refund_items.deep_dup
        item = items.find { |row| row["refund_no"] == refund_no }
        return false unless item && item["status"] == "processing"
        return true if item["attempted"]

        time = Time.current.iso8601
        item.merge!("attempted" => true, "submitted_at" => time, "updated_at" => time)
        @appointment.write_refunds!(items)
        @appointment.record_event!("refund_submit", **@audit, details: refund_details(item))
        true
      end

      def apply!(result)
        result.fetch(:kind) == :payment ? apply_payment!(result) : apply_refund!(result)
      end

      private

      def patient_requested_close?
        return @appointment.payment_data["patient_requested_close"] if @appointment.payment_data.key?("patient_requested_close")
        requested = @appointment.payment_cancel_requested_at
        return false unless requested && @appointment.payment_expires_at && requested < @appointment.payment_expires_at

        # Orders already closing at upgrade only have the original audit entry.
        Log.where(target_type: "Appointment", target_id: @appointment.id, action: "appointment.payment_close_requested", source: "user")
          .exists?(["details ->> 'reason' = ?", "patient_requested"])
      end

      def apply_payment!(result)
        state = result.fetch(:state)
        case state
        when "SUCCESS"
          return true if @appointment.payment_status == "paid"
          raise Payments::InvalidResult unless @appointment.pending_payment?

          @appointment.update!(status: "confirmed", payment_status: "paid", transaction_no: result.fetch(:transaction_id),
            paid_amount_cents: result.fetch(:paid_cents), paid_at: result.fetch(:paid_at),
            payment_data: @appointment.payment_data.merge("trade_state" => state))
          @appointment.record_event!("payment_confirmed", **@audit,
            details: { payment_no: @appointment.payment_no, paid_amount_cents: @appointment.paid_amount_cents })
          GroupNotice.publish("appointment_confirmed", @appointment)
        when "CLOSED"
          close_unpaid!(state)
        else
          if @appointment.pending_payment?
            data = @appointment.payment_data.merge("trade_state" => state)
            case data["prepay_outcome"]
            when "in_flight" then data["prepay_outcome"] = "in_flight_order_found"
            when "rejected" then data["prepay_outcome"] = "accepted"
            end
            @appointment.update!(payment_data: data) if data != @appointment.payment_data
          end
        end
        true
      end

      def apply_refund!(result)
        items = @appointment.refund_items.deep_dup
        item = items.find { |row| row["refund_no"] == result.fetch(:refund_no) }
        raise Payments::InvalidResult unless item && item["status"].in?(%w[processing succeeded failed])

        state = result.fetch(:state)
        case item["status"]
        when "succeeded"
          return true unless state == "SUCCESS"
        when "failed"
          # A verified closed refund releases the reservation for a new application.
          raise Payments::InvalidResult if state == "SUCCESS"
          return true
        end
        return true if item["provider_state"] == "ABNORMAL" && state == "PROCESSING"

        attention_states = %w[ABNORMAL CLOSED]
        needs_attention = attention_states.include?(state) && !attention_states.include?(item["provider_state"])
        changes = {
          "provider_refund_no" => result.fetch(:refund_id), "provider_state" => state,
          "status" => { "SUCCESS" => "succeeded", "CLOSED" => "failed" }.fetch(state, "processing")
        }
        if state == "SUCCESS"
          changes["payer_refund_cents"] = result[:payer_refund_cents] unless result[:payer_refund_cents].nil?
          changes["refunded_at"] = result[:refunded_at].iso8601 if item["refunded_at"].nil? && result[:refunded_at]
        end
        return true if item.slice(*changes.keys) == changes && item["error_code"].nil?

        item.delete("error_code")
        item.merge!(changes, "updated_at" => Time.current.iso8601)
        @appointment.write_refunds!(items)
        @appointment.record_event!("refund_result", **@audit, details: refund_details(item).merge(
          channel_outcome: state, payer_refund_cents: item["payer_refund_cents"]
        ).compact)
        GroupNotice.publish("refund_attention", @appointment, item) if needs_attention
        true
      end

      def refund_details(item)
        { refund_record_id: item.fetch("id"), refund_no: item.fetch("refund_no"), amount_cents: item.fetch("amount_cents") }
      end
    end
  end
end
