module Admins
  class PageLinksController < BaseController
    class FallbackConfirmationRequired < StandardError; end

    skip_before_action :refresh_storage_configuration
    before_action :require_super_admin!
    before_action :refresh_storage_configuration
    before_action :load_scope, only: %i[index new create]
    before_action :load_link, only: %i[edit update status destroy image]

    def index
      @group = PageLinkConfiguration.new(app: @app).groups.fetch(@position)
      @managed = @app.nil? || @group.source == :app
      rows = @managed ? @group.records : @group.effective
      @pagy = Pagy::Offset.new(count: rows.size, page: [ params[:page].to_s.to_i, 1 ].max, limit: 20)
      @links = rows.slice(@pagy.offset, @pagy.limit)
      apps = App.wechat_mini_programs.order(:nickname, :appid).to_a
      names = ([ "通用配置" ] + apps.map(&:display_name)).tally
      @scope_options = { nil => "通用配置" }
      apps.each do |app|
        name = app.display_name
        @scope_options[app.id] = names.fetch(name) > 1 ? "#{name} · #{app.appid}" : name
      end
    end

    def new
      @link = Link.new(app: @app, position: @position)
    end

    def create
      @link = Link.new(app: @app, position: @position)
      save_link(:create, :new)
    end

    def edit
      @page_query = URI.encode_www_form(@link.params.fetch("query", {}))
    end

    def update
      save_link(:update, :edit)
    end

    def status
      desired = params.expect(:status)
      action = desired == "active" ? :enable : :disable
      @link.with_lock do
        if @link.status != desired
          @link.update!(status: desired)
          audit(action, fields: [ "status" ], status_value: desired)
        end
      end
      redirect_to list_path, notice: "#{@link.item_label}#{Link::STATUSES.fetch(@link.status)}", status: :see_other
    rescue ActiveRecord::ActiveRecordError => error
      failed_action(action, error.is_a?(ActiveRecord::RecordInvalid) ? @link.errors.first&.message : "状态未能保存，请重试")
    end

    def destroy
      Link.transaction(requires_new: true) do
        # Serialize deletions within an app so two open confirmations cannot silently restore the defaults.
        @app&.lock!
        @link.lock!
        if @app && params[:restore_shared] != "1" && @app.links.where(position: @position).one?
          raise FallbackConfirmationRequired, "此位置只剩一条专属记录。请重新确认，删除后，此位置将恢复通用配置。"
        end

        @link.destroy!
        audit(:destroy)
      end
      redirect_to list_path, notice: "#{@link.item_label}已删除", status: :see_other
    rescue FallbackConfirmationRequired => error
      failed_action(:destroy, error.message)
    rescue ActiveRecord::RecordNotDestroyed, ActiveRecord::StatementInvalid
      failed_action(:destroy, "删除失败，请刷新页面后重试")
    end

    def image
      raise ActiveRecord::RecordNotFound unless @link.image.attached?

      send_data @link.image.download, type: @link.image.content_type, disposition: "inline", filename: @link.image.blob.key
    rescue ActiveStorage::FileNotFoundError
      head :not_found
    end

    private

    def load_scope
      @app = App.wechat_mini_programs.find(params[:app_id]) if params[:app_id].present?
      @position = params.fetch(:position, "home_banner")
      raise ActiveRecord::RecordNotFound unless Link::POSITIONS.key?(@position)
    end

    def load_link
      @link = Link.find(params[:id])
      @app = @link.app
      @position = @link.position
    end

    def list_path = admins_page_links_path(app_id: @app&.id, position: @position)

    def save_link(action, template)
      input = params.require(:link).permit(:name, :link_type, :url, :sort_order, :status, :target_appid, :page_query, :image, :remove_image)
      attributes = link_attributes(input, action)
      if input[:image].present?
        MediaUpload.attach(input[:image], as: :link_image) { |blob| persist_link(action, attributes, blob:) }
      else
        persist_link(action, attributes, remove_image: !@link.banner? && input[:remove_image] == "1")
      end
      redirect_to list_path, notice: "#{@link.item_label}已保存", status: :see_other
    rescue MediaUpload::Invalid, MediaUpload::Failed, ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => error
      @link.attachment_changes.delete("image")
      @link.association(:image_attachment).reset
      @link.association(:image_blob).reset
      @link.assign_attributes(attributes)
      if error.is_a?(MediaUpload::Invalid) || error.is_a?(MediaUpload::Failed)
        @link.errors.add(:image, error.message)
      end
      @link.errors.add(:base, "配置未能保存，请刷新页面后重试") if @link.errors.empty?
      audit(action, status: "failed", reason: "保存失败", fields: @link.errors.attribute_names)
      render template, status: :unprocessable_content
    end

    def link_attributes(input, action)
      values = input.slice(:name, :link_type, :url, :sort_order).to_h
      values[:status] = input[:status] if action == :create && input.key?(:status)
      values[:url] = nil if %w[none contact].include?(input[:link_type])
      values[:params] = {}
      if input[:link_type] == "miniprogram"
        @page_query = input[:page_query].to_s.strip
        values[:params]["target_appid"] = input[:target_appid].to_s.strip
        values[:params]["query"] = page_query if @page_query.present?
      end
      values
    end

    def page_query
      pairs = URI.decode_www_form(@page_query)
      pairs.size == pairs.to_h.size ? pairs.to_h : @page_query
    rescue ArgumentError
      @page_query
    end

    def persist_link(action, attributes, blob: nil, remove_image: false)
      Link.transaction(requires_new: true) do
        @link.lock! if @link.persisted?
        @link.assign_attributes(attributes)
        replace_image = blob || (remove_image && @link.image.attached?)
        @link.image = blob if replace_image
        fields = @link.changed + (replace_image ? [ "image" ] : [])
        @link.save!
        if action == :update && fields.delete("sort_order")
          audit(:reorder, fields: [ "sort_order" ], sort_order: @link.sort_order)
        end
        audit(action, fields:) if action == :create || fields.any?
      end
    end

    def failed_action(action, reason)
      audit(action, status: "failed", reason: reason)
      redirect_to list_path, alert: reason, status: :see_other
    end

    def audit(action, status: "success", **details)
      Log.record!(category: "app", action: "link.#{action}", actor: current_admin, target: @link, request: request, status: status,
        details: { app_id: @link.app_id, position: @link.position, **details }.compact)
    end
  end
end
