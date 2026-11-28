module Appointments
  class Refunds
    RETRY_INTERVAL = 1.minute
    REASON_LIMIT = 500

    def initialize(appointment, source:, actor: nil, request: nil)
      @appointment, @actor = appointment, actor
      @audit = { source: source, actor: actor, request: request }
      @payments = Payments.new(receiver: PaymentReceiver.new(**@audit))
    end

    def request!(kind:, key:, reason: nil, amount: nil, confirmed_available: nil)
      @appointment.with_lock do
        unless staff? || (kind == "cancel" && @actor.is_a?(User) && @actor.id == @appointment.user_id)
          raise Appointment::InvalidOperation, "没有办理权限"
        end
        raise Appointment::InvalidOperation, "请重新打开预约详情后提交" unless Create::KEY_FORMAT.match?(key.to_s)

        items = @appointment.refund_items.deep_dup
        if (previous = items.find { |row| row["idempotency_key"] == key })
          unless previous.values_at("kind", "requested_by_type", "requested_by_id") == [ kind, @actor.class.name, @actor.id ]
            raise Appointment::InvalidOperation, "请重新打开预约详情后提交"
          end
          next previous.fetch("id")
        end

        if kind == "cancel"
          active = @appointment.active_refunds.find { |row| row["kind"] == "cancel" }
          if active
            raise Appointment::InvalidOperation, "请在原申请上处理退号" if staff? && active["status"] == "requested"

            next active.fetch("id")
          end
        end
        check_confirmation!(confirmed_available, kind) if staff?
        cents = request_amount!(kind, amount)
        explanation = checked_note(reason, required: staff?)
        time = Time.current.iso8601
        item = {
          "id" => items.map { |row| row.fetch("id") }.max.to_i + 1, "refund_no" => reserve_refund_no!,
          "kind" => kind, "amount_cents" => cents, "reason" => explanation, "status" => "requested",
          "requested_by_type" => @actor.class.name, "requested_by_id" => @actor.id, "idempotency_key" => key,
          "created_at" => time, "updated_at" => time
        }
        items << item
        attributes = {}
        if kind == "cancel" && @appointment.status == "confirmed"
          attributes = { status: "cancel_requested", cancel_requested_at: Time.current }
        end
        auto = staff? || !AppointmentSettings.new(lock: "FOR SHARE").refund_requires_review?
        attributes.merge!(approve!(item)) if auto
        @appointment.write_refunds!(items, **attributes)
        event!(staff? ? "hospital_refund" : "refund_request", item, automatic: auto, outcome: item.fetch("status"))
        if attributes[:cancelled_at]
          GroupNotice.publish("appointment_returned", @appointment, item)
        elsif !auto && kind == "cancel"
          GroupNotice.publish("return_requested", @appointment, item)
        end
        item.fetch("id")
      end
    end

    def review!(id, decision:, note: nil, confirmed_available: nil)
      require_staff!
      unless %w[approve reject].include?(decision)
        raise Appointment::InvalidOperation, "请选择有效的审核结果"
      end

      @appointment.with_lock do
        items = @appointment.refund_items.deep_dup
        item = find_item!(items, id)
        unless item["status"] == "requested"
          unchanged = decision == "approve" ? item["review_decision"] == "approve" : item["status"] == "rejected"
          raise Appointment::InvalidOperation, "申请已处理，请核对最新状态" unless unchanged
          next
        end

        review_item!(item, decision, checked_note(note, required: decision == "reject"))
        attributes = if decision == "approve"
          check_confirmation!(confirmed_available, item.fetch("kind"), item: item)
          item["amount_cents"] = @appointment.remaining_gross_cents if item["kind"] == "cancel"
          approve!(item)
        else
          item["status"] = "rejected"
          restore_booking(item)
        end
        @appointment.write_refunds!(items, **attributes)
        event!("refund_review", item, decision: decision, outcome: item.fetch("status"))
        GroupNotice.publish("appointment_returned", @appointment, item) if attributes[:cancelled_at]
      end
    end

    def complete_visit!
      require_staff!
      @appointment.with_lock do
        next if @appointment.status == "completed"
        raise Appointment::InvalidOperation, "当前状态无法登记已就诊" unless @appointment.can_complete?

        attributes = { status: "completed", completed_at: Time.current, completed_by_admin: @actor }
        items = @appointment.refund_items.deep_dup
        pending = items.find { |row| row["kind"] == "cancel" && row["status"] == "requested" }
        if pending
          review_item!(pending, "reject", "医院已登记就诊")
          pending["status"] = "rejected"
          @appointment.write_refunds!(items, **attributes)
          event!("refund_review", pending, decision: "reject", reason: "visit_completed")
        else
          @appointment.update!(**attributes)
        end
        @appointment.record_event!("complete", **@audit)
      end
    end

    def reconcile!(id)
      refund_no = @appointment.with_lock do
        items = @appointment.refund_items.deep_dup
        item = find_item!(items, id)
        next unless item["status"].in?(%w[approved processing])
        next if item["next_check_at"] && Time.iso8601(item["next_check_at"]).future?

        if item["status"] == "approved" && item["kind"] == "cancel"
          next if @appointment.refund_difference_pending?

          item["amount_cents"] = @appointment.remaining_gross_cents
          if item["amount_cents"].zero?
            item.merge!("status" => "succeeded", "updated_at" => Time.current.iso8601)
            @appointment.write_refunds!(items)
            event!("return_completed", item)
            next
          end
        end
        item.merge!("status" => "processing", "updated_at" => Time.current.iso8601,
          "next_check_at" => RETRY_INTERVAL.from_now.iso8601)
        @appointment.write_refunds!(items)
        item.fetch("refund_no")
      end
      @payments.refund(@appointment.payment_no, refund_no: refund_no) if refund_no
    rescue Payments::Error, WechatPaySettings::Invalid => error
      record_unknown!(id, error)
    ensure
      @appointment.reload
    end

    def sync!(id)
      require_staff!
      item = find_item!(@appointment.reload.refund_items, id)
      unless item["attempted"]
        record_sync_failure(item, "该申请尚未提交微信")
        raise Appointment::InvalidOperation, "该申请尚未提交微信"
      end

      @payments.query_refund(@appointment.payment_no, refund_no: item.fetch("refund_no")) do
        raise ActiveRecord::RecordNotSaved unless event!("refund_sync", item).persisted?
      end
    rescue Payments::Error, WechatPaySettings::Invalid
      record_sync_failure(item, "微信退款查询失败")
      raise Appointment::InvalidOperation, "微信退款结果待核实，请稍后重试"
    end

    private

    def record_sync_failure(item, reason)
      event!("refund_sync", item, status: "failed", reason: reason)
    rescue ActiveRecord::ActiveRecordError
      Rails.logger.warn("核对退款失败审计未能写入")
    end

    def staff? = @actor.is_a?(Admin) && @actor.enabled? && @actor.maintain_booking_directory?

    def require_staff!
      raise Appointment::InvalidOperation, "没有办理权限" unless staff?
    end

    def find_item!(items, id)
      items.find { |row| row.fetch("id").to_s == id.to_s } || raise(ActiveRecord::RecordNotFound)
    end

    def check_confirmation!(confirmed_available, kind, item: nil)
      available = @appointment.refund_confirmation_balance(item)
      unless confirmed_available.to_s == available.to_s
        raise Appointment::InvalidOperation, "可退金额已更新，当前可退 #{Appointment.cents_in_yuan(available)} 元，请重新核对并确认"
      end
      if kind == "cancel" && @appointment.refund_difference_pending?
        raise Appointment::InvalidOperation, "已有退差价尚未办结，请核对结果后再确认退号"
      end
    end

    def request_amount!(kind, amount)
      if kind == "cancel"
        allowed = staff? ? @appointment.hospital_can_return? : @appointment.patient_can_return?
        raise Appointment::InvalidOperation, "当前预约无法退号，请联系医院核对" unless allowed

        return @appointment.remaining_gross_cents if @appointment.active_refunds.empty?
        return
      end

      unless staff? && kind == "admin_refund" && @appointment.price_refund_allowed?
        raise Appointment::InvalidOperation, "当前预约无法办理退差价"
      end
      value = amount.to_s.strip
      cents = (BigDecimal(value) * 100).to_i if /\A[0-9]{1,10}(?:\.[0-9]{1,2})?\z/.match?(value)
      unless cents&.positive? && cents <= @appointment.available_refund_cents
        raise Appointment::InvalidOperation, "请输入大于 0 且不超过剩余可退金额的金额，最多两位小数"
      end
      cents
    end

    def checked_note(value, required:)
      note = value.to_s.strip.presence
      raise Appointment::InvalidOperation, "请填写原因" if required && note.nil?
      raise Appointment::InvalidOperation, "原因最多 #{REASON_LIMIT} 字" if note && note.length > REASON_LIMIT

      note
    end

    def reserve_refund_no!
      5.times do
        number = Appointment.generate_order_no
        lock_name = Appointment.connection.quote("appointment-refund:#{number}")
        Appointment.connection.execute("SELECT pg_advisory_xact_lock(hashtextextended(#{lock_name}, 0))")
        return number unless Appointment.exists?([ "refund_data @> ?::jsonb", { items: [ { refund_no: number } ] }.to_json ])
      end
      raise Appointment::InvalidOperation, "暂时无法生成退款单号，请重试"
    end

    def review_item!(item, decision, note)
      time = Time.current.iso8601
      item.merge!("review_decision" => decision, "reviewed_by_admin_id" => @actor.id, "review_note" => note,
        "reviewed_at" => time, "updated_at" => time)
    end

    def approve!(item)
      item["status"] = "approved"
      return {} unless item["kind"] == "cancel" && @appointment.status != "cancelled"

      { status: "cancelled", cancelled_at: Time.current }
    end

    def restore_booking(item)
      item["kind"] == "cancel" && @appointment.status == "cancel_requested" ? { status: "confirmed" } : {}
    end

    def record_unknown!(id, error)
      @appointment.with_lock do
        items = @appointment.refund_items.deep_dup
        item = find_item!(items, id)
        next unless item["status"] == "processing"

        code = error.is_a?(Payments::ChannelError) ? error.code : error.class.name.demodulize
        next if item["error_code"] == code

        item.merge!("error_code" => code, "updated_at" => Time.current.iso8601)
        item["provider_state"] ||= "unknown"
        @appointment.write_refunds!(items)
        event!("refund_pending", item, error_code: code)
      end
    end

    def event!(action, item, status: "success", **details)
      @appointment.record_event!(action, **@audit, status: status, details: details.merge(
        refund_record_id: item.fetch("id"), refund_no: item.fetch("refund_no"),
        kind: item.fetch("kind"), amount_cents: item["amount_cents"]
      ).compact)
    end
  end
end
