module Admins
  class HospitalNoticesController < BaseController
    before_action :require_super_admin!
    before_action :load_template, only: %i[edit update enable disable]
    before_action :load_event, except: %i[index enable disable]
    rescue_from Notifications::Error do |error|
      if action_name.in?(%w[new edit]) && request.format.html?
        render :registration_error, status: :unprocessable_content
        next
      end
      audit(action_name, status: "failed") if action_name.in?(%w[create update])
      render json: error.is_a?(Notifications::FieldError) ? error.feedback : { error: error.message }, status: :unprocessable_content
    end

    def index
      @kind = params[:event].presence
      scope = HospitalNoticeTemplate.order(id: :desc)
      scope = scope.where(event: @kind) if @kind
      @pagy, @templates = pagy(scope)
    end

    def new
      @template = HospitalNoticeTemplate.new(event: @kind, messages: @source&.messages)
      @template.name = "#{@source.name.first(76)}（副本）" if @source
      prepare_editor
      render :edit
    end

    def edit = prepare_editor

    def preview
      examples = @variable_fields.transform_values { |field| field.fetch("example") }
      rendered = Appointments::GroupNotice.render(messages, fields: @variable_fields, data: examples)
      render json: { texts: Notifications::Channels::WecomGroup.split_messages(rendered).map { |m| m.dig("content", "text") } }
    end

    def create
      @template = HospitalNoticeTemplate.new(event: @kind)
      save_content
    end

    def update
      @template.with_lock do
        raise Notifications::Error, "文案已变化，请刷新后保存" unless input[:revision] == @template.revision
        save_content
      end
    end

    def enable
      change_enabled(true)
    end

    def disable
      change_enabled(false)
    end

    private

    def change_enabled(value)
      @template.change_enabled!(value) { audit(action_name) }
      redirect_to admins_hospital_notices_path, status: :see_other
    rescue ActiveRecord::ActiveRecordError, Notifications::Error
      reason = value ? "模板启用失败" : "模板停用失败"
      begin
        audit(action_name, status: "failed", details: { reason: reason })
      rescue ActiveRecord::ActiveRecordError
        Rails.logger.warn("通知模板失败审计未能写入")
      end
      respond_to do |format|
        format.html { redirect_to admins_hospital_notices_path, alert: reason, status: :see_other }
        format.json { render json: { error: reason }, status: :unprocessable_content }
      end
    end

    def prepare_editor
      text = "{event_name}\n预约号：{order_no}"
      text += "\n{result}，本次已确认现金实退：{refunded}" if @kind == "appointment_returned"
      text += "\n{failure_reason}" if @kind == "refund_attention"
      default = { "id" => "notice", "type" => "text", "content" => { "text" => text } }
      @reply = { "name" => @template.name, "messages" => @template.messages || [default] }
      @input = { id: @template.id, revision: @template.revision }
      @variable_examples = @variable_fields.transform_values { |field| field.fetch("example") }
    end

    def save_content
      contents = messages
      Notifications::Variables.validate!(contents, fields: @variable_fields)
      action = @template.persisted? ? "update" : "create"
      HospitalNoticeTemplate.transaction do
        @template.assign_attributes(name: input[:name].to_s.strip, messages: contents)
        raise Notifications::FieldError.new("请填写 1～80 字的模板名称", field: "name") unless @template.valid?
        @template.save!
        audit(action)
      end
      flash[:notice] = "模板已保存"
      render json: { saved: true }
    end

    def audit(action, status: "success", details: {})
      entry = Log.record!(category: "notification", action: "notification.hospital_#{action}", actor: current_admin,
        target: @template, request: request, status: status, details: details)
      raise ActiveRecord::RecordNotSaved unless entry.persisted?
    end

    def load_template
      @template = HospitalNoticeTemplate.find(params[:id])
    end

    def load_event
      @source = HospitalNoticeTemplate.find(params[:copy_id]) if action_name == "new" && params[:copy_id].present?
      @kind = @template&.event || @source&.event || params[:event].presence || "appointment_confirmed"
      raise ActiveRecord::RecordNotFound unless Appointments::GroupNotice::EVENTS.key?(@kind)
      @variable_fields = Notifications::EventCatalog.fetch(@kind).fetch("fields")
    end

    def input
      @input_params ||= params.require(:notification_content).permit(:revision, :name, messages: [:id, :type, { content: [:text] }])
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
