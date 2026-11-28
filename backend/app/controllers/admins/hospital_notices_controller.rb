module Admins
  class HospitalNoticesController < BaseController
    before_action :require_super_admin!
    before_action :load_event
    rescue_from Notifications::Error do |error|
      render json: error.is_a?(Notifications::FieldError) ? error.feedback : { error: error.message }, status: :unprocessable_content
    end

    def edit
      @stored = Setting.find_by(key: @setting_key)&.settings || {}
      text = "{event_name}\n预约号：{order_no}"
      text += "\n{result}，本次已确认现金实退：{refunded}" if @kind == "appointment_returned"
      text += "\n{failure_reason}" if @kind == "refund_attention"
      default = { "id" => "notice", "type" => "text", "content" => { "text" => text } }
      @reply = { name: Appointments::GroupNotice::EVENTS.fetch(@kind), messages: @stored.fetch("messages", [default]) }.stringify_keys
      @input = { id: @kind, revision: revision(@stored) }
      @variable_examples = @variable_fields.transform_values { |field| field.fetch("example") }
    end

    def preview
      examples = @variable_fields.transform_values { |field| field.fetch("example") }
      rendered = Notifications::Variables.render(messages, fields: @variable_fields, data: examples, max_text_bytes: nil)
      render json: { texts: Notifications::Channels::WecomGroup.split_messages(rendered).map { |m| m.dig("content", "text") } }
    end

    def update
      contents = messages
      Notifications::Variables.validate!(contents, fields: @variable_fields)
      Setting.transaction do
        Setting.connection.execute("SELECT pg_advisory_xact_lock(71020013)")
        row = Setting.find_or_initialize_by(key: @setting_key)
        raise Notifications::Error, "文案已变化，请刷新后保存" unless input[:revision] == revision(row.settings || {})
        row.update!(settings: { messages: contents, enabled: input[:enabled] == true })
        Log.record!(category: "notification", action: "notification.wecom_content", actor: current_admin, target: row,
          request: request, details: { event: @kind, fields: %w[messages enabled] })
      end
      flash[:notice] = "医院业务通知已保存"
      render json: { saved: true }
    end

    private

    def revision(data) = Digest::SHA256.hexdigest(data.to_json)

    def load_event
      @kind = params[:event].presence || "appointment_confirmed"
      raise ActiveRecord::RecordNotFound unless Appointments::GroupNotice::EVENTS.key?(@kind)
      @setting_key = Appointments::GroupNotice.setting_key(@kind)
      @variable_fields = Notifications::EventCatalog.fetch(@kind).fetch("fields")
    end

    def input
      @input_params ||= params.require(:notification_content).permit(:revision, :enabled, messages: [:id, :type, { content: [:text] }])
    end

    def messages
      rows = input[:messages]
      raise Notifications::Error, "请新增 1～8 条文字消息" unless rows.is_a?(Array) && rows.size.between?(1, 8)
      rows.map.with_index do |row, index|
        text = row.dig(:content, :text)
        unless row[:type] == "text" && text.is_a?(String) && text.present? && text.bytesize <= 2048
          raise Notifications::FieldError.new("文字应为 1～2048 字节", field: "text", message_index: index)
        end
        { "id" => "msg_#{index + 1}", "type" => "text", "content" => { "text" => text } }
      end
    end
  end
end
