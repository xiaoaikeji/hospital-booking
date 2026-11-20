module Admins
  class PostersController < BaseController
    before_action :require_super_admin!
    before_action :load_poster, only: %i[edit update background]

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

    private

    def load_poster = @poster = Poster.find(params[:id])
    def poster_params = params.require(:poster).permit(*Poster::FIELDS)

    def prepare_options
      @apps = App.wechat_accounts.where.not(status: "disabled").order(:id)
      @codes = OfficialAccountQrcode.where(app_id: @apps.select(:id)).includes(:app).order(:id)
    end
  end
end
