module Admins
  class PostersController < BaseController
    before_action :require_super_admin!
    before_action :load_poster, only: %i[edit update destroy background]

    def index
      @pagy, @posters = pagy(Poster.with_attached_background.includes(:app).order(id: :desc))
    end

    def new
      @poster = Poster.new
    end

    def create
      @poster = Poster.new
      if PosterSaving.call(@poster, attributes: poster_params.slice(:name), file: params.dig(:poster, :background), actor: current_admin, request: request)
        redirect_to edit_admins_poster_path(@poster), notice: "底图已保存，请选择扫码目标并调整位置", status: :see_other
      else
        render :new, status: :unprocessable_content
      end
    end

    def edit
      prepare_options
    end

    def update
      if PosterSaving.call(@poster, attributes: poster_params, file: params.dig(:poster, :background), actor: current_admin, request: request)
        redirect_to edit_admins_poster_path(@poster), notice: "海报已保存", status: :see_other
      else
        prepare_options
        render :edit, status: :unprocessable_content
      end
    end

    def background
      raise ActiveRecord::RecordNotFound unless @poster.background.attached?
      send_data @poster.background.download, type: @poster.background.content_type, disposition: "inline", filename: @poster.background.blob.key
    end

    def destroy
      @poster.with_lock do
        @poster.destroy!
        Log.record!(category: "poster", action: "poster.delete", actor: current_admin, target: @poster, request: request)
      end
      redirect_to admins_posters_path, notice: "海报已删除", status: :see_other
    rescue ActiveRecord::ActiveRecordError
      Log.record!(category: "poster", action: "poster.delete", actor: current_admin, target: @poster, request: request,
        status: "failed", details: { reason: "海报删除失败" })
      redirect_to edit_admins_poster_path(@poster), alert: "海报删除失败，请重试", status: :see_other
    end

    private

    def load_poster = @poster = Poster.find(params[:id])
    def poster_params = params.require(:poster).permit(*Poster::FIELDS)

    def prepare_options
      @apps = App.wechat_accounts.where.not(status: "disabled").order(:id)
      @codes = OfficialAccountQrcode.where(app_id: @apps.select(:id)).includes(:app).order(:id)
    end
  end
end
