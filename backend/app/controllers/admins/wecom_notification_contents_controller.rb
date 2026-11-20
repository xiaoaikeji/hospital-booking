module Admins
  class WecomNotificationContentsController < BaseController
    before_action :require_super_admin!
    before_action :load_content
    rescue_from Notifications::Error, with: :failed

    def edit
      @reply = { "name" => WechatPlatform::NotificationSettings::LABELS.fetch(@kind), "messages" => @content.messages }
      @input = { id: @kind, revision: @content.revision }
      @variable_fields = WechatPlatform::NotificationContents.fields(@kind)
      @variable_examples = @variable_fields.transform_values { |field| field["example"] }
    end

    def update
      input = params.require(:notification_content).permit(:revision, :restore, :send_interval, messages: [ :id, :type, { content: [ :text ] } ]).to_h
      restore = input[:restore] == "1"
      @content.save!(input[:messages], revision: input[:revision], actor: current_admin, request: request, restore: restore,
        send_interval: input.fetch("send_interval") { @content.send_interval })
      flash[:notice] = restore ? "已恢复默认通知文案" : "企微通知文案已保存"
      if restore
        redirect_to edit_admins_wecom_notification_content_path(event: @kind), status: :see_other
      else
        render json: { revision: @content.revision }
      end
    end

    private

    def load_content
      @kind = params[:event].presence || "passed"
      raise ActiveRecord::RecordNotFound unless WechatPlatform::NotificationSettings::LABELS.key?(@kind)
      @content = WechatPlatform::NotificationContents.new(@kind)
    end

    def failed(error)
      if request.format.json?
        feedback = error.is_a?(Notifications::FieldError) ? error.feedback : { error: error.message }
        render json: feedback, status: :unprocessable_content
      else
        redirect_to edit_admins_wecom_notification_content_path(event: @kind), alert: error.message, status: :see_other
      end
    end
  end
end
