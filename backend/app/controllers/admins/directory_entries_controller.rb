module Admins
  class DirectoryEntriesController < BaseController
    SAVE_FAILURE = "资料未保存，请重试"
    STATUS_FAILURE = "状态未能保存，请重试"

    skip_before_action :refresh_storage_configuration
    before_action :require_directory_editor!, only: %i[new create edit update status]
    before_action :load_entry, only: %i[show edit update status image]

    helper_method :entry_title, :entry_label, :entry_model, :directory_path, :image_label, :upload_limit

    def index
      @status = params[:status].presence_in(%w[0 1])&.to_i
      rows = list_scope.ordered.with_attached_image
      rows = rows.where(status: @status) if @status
      @pagy, @entries = pagy(:offset, rows, limit: 20)
      render "admins/directory_entries/index"
    end

    def new
      @entry = entry_scope.new
      render_form(:new)
    end

    def show
      @details = entry_details.merge("排序" => @entry.sort_order.to_s, "状态" => DirectoryEntry::STATUSES.fetch(@entry.status))
      render "admins/directory_entries/show"
    end

    def create
      @entry = entry_scope.new
      save_entry(:create, :new)
    end

    def edit
      render_form(:edit)
    end

    def update
      save_entry(:update, :edit)
    end

    def status
      desired = params.expect(:status).to_s
      raise ActionController::BadRequest unless %w[0 1].include?(desired)

      action = desired == "1" ? :enable : :disable
      @entry.with_lock(requires_new: true) do
        if @entry.status != desired.to_i
          @entry.update!(status: desired)
          audit(action, fields: [ "status" ], status_value: @entry.status)
        end
      end
      redirect_to directory_path, notice: "#{entry_label}#{DirectoryEntry::STATUSES.fetch(@entry.status)}", status: :see_other
    rescue ActiveRecord::ActiveRecordError => error
      audit(action, status: "failed", reason: STATUS_FAILURE)
      reason = @entry.errors[:status].first if error.is_a?(ActiveRecord::RecordInvalid) && error.record == @entry
      redirect_to directory_path, alert: reason || STATUS_FAILURE, status: :see_other
    end

    def image
      image = @entry.image
      return head :not_found unless image.attached?

      refresh_storage_configuration
      send_data image.download, type: image.content_type, disposition: "inline", filename: image.blob.key
    rescue ActiveStorage::FileNotFoundError
      head :not_found
    end

    private

    def entry_model = self.class::ENTRY_MODEL
    def entry_title = self.class::ENTRY_TITLE
    def entry_label = self.class::ENTRY_LABEL
    def entry_scope = entry_model.all
    def list_scope = entry_scope
    def directory_path(**query) = polymorphic_path([ :admins, entry_model ], **query)
    def image_label = "图标"
    def upload_purpose = :directory_icon
    def upload_limit = MediaUpload::PURPOSES.fetch(upload_purpose).fetch(:limit) / 1.megabyte
    def permitted_fields = %i[name sort_order status image remove_image]
    def load_entry = @entry = entry_scope.find(params[:id])
    def form_options; end

    def require_directory_editor!
      render file: Rails.public_path.join("403.html"), layout: false, status: :forbidden unless current_admin.maintain_booking_directory?
    end

    def render_form(mode, status: :ok)
      form_options
      title = "#{mode == :new ? '新增' : '编辑'}#{entry_label}"
      render "admins/directory_entries/form", locals: { title: title }, status: status
    end

    def save_entry(action, mode)
      input = params.expect(entry_model.model_name.param_key => permitted_fields)
      attributes = input.except(:image, :remove_image)
      attributes.delete(:status) if action == :update
      if input[:image].present?
        refresh_storage_configuration
        MediaUpload.attach(input[:image], as: upload_purpose) { |blob| persist_entry(action, attributes, blob:) }
      else
        persist_entry(action, attributes, remove_image: input[:remove_image] == "1")
      end
      redirect_to directory_path, notice: "#{entry_label}已保存", status: :see_other
    rescue IntegrationSettings::ConfigurationError
      audit(action, status: "failed", reason: SAVE_FAILURE)
      raise
    rescue MediaUpload::Invalid, MediaUpload::Failed, ActiveRecord::ActiveRecordError => error
      @submitted_attributes = attributes
      @entry.attachment_changes.delete("image")
      @entry.association(:image_attachment).reset
      @entry.association(:image_blob).reset
      @entry.assign_attributes(entry_attributes(attributes))
      @entry.errors.add(:image, error.message) if error.is_a?(MediaUpload::Invalid) || error.is_a?(MediaUpload::Failed)
      @entry.errors.add(:base, SAVE_FAILURE) if @entry.errors.empty?
      audit(action, status: "failed", reason: SAVE_FAILURE)
      render_form(mode, status: :unprocessable_content)
    end

    def persist_entry(action, attributes, blob: nil, remove_image: false)
      entry_model.transaction(requires_new: true) do
        @entry.lock! if @entry.persisted?
        fields = assign_entry_attributes(attributes)
        if blob || (remove_image && @entry.image.attached?)
          @entry.image = blob
          fields << "image"
        end
        @entry.save!
        fields += @entry.saved_changes.keys - %w[id created_at updated_at]
        audit_changes(action, fields)
      end
    end

    def assign_entry_attributes(attributes)
      @entry.assign_attributes(entry_attributes(attributes))
      []
    end

    def entry_attributes(attributes) = attributes

    def audit_changes(action, fields)
      audit_update_fields(fields) if action == :update
      audit(action, fields:) if action == :create || fields.any?
    end

    def audit_update_fields(fields)
      if fields.delete("sort_order")
        audit(:reorder, fields: [ "sort_order" ], sort_order: @entry.sort_order)
      end
    end

    def audit(action, status: "success", **details)
      Log.record!(category: "booking", action: "#{entry_model.model_name.singular}.#{action}", status: status,
        actor: current_admin, target: @entry, request: request, details: details)
    end
  end
end
