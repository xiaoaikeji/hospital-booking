module Admins
  class ReplyContentsController < BaseController
    before_action :require_super_admin!
    before_action :load_account, except: :index
    rescue_from Notifications::Error, Wechat::Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable, with: :failed

    def index
      @accounts = App.wechat_official_accounts.order(:nickname, :id)
      @app = params[:app_id].present? ? @accounts.find(params[:app_id]) : @accounts.first
      @replies = @app ? Notifications::AccountConfiguration.new(@app).replies : {}
    end

    def new
      @reply = params.key?(:menu_index) ? existing_menu_text : { "name" => "", "messages" => [] }
      prepare_editor
    end

    def edit
      @reply = configuration.reply(params[:id])
      prepare_editor
    end

    def create = save_reply
    def update = save_reply

    def media
      render json: Wechat::OfficialAccountMenus.new(@app, actor: current_admin, request: request).upload_card_cover!(params[:file])
    end

    def image
      id = params[:media_id].to_s
      own = configuration.replies.values.any? { |reply| reply["messages"].any? { |m| m["type"] == "miniprogrampage" && m.dig("content", "thumb_media_id") == id } }
      proof = Rails.application.message_verifier(:official_menu_resource).verified(params[:proof].to_s)
      raise ActiveRecord::RecordNotFound unless own || proof == [ @app.id, "card_cover", id ]
      bytes, mime = Wechat::AccessToken.with_token(@app) { |token| Wechat::OfficialAccountMenuClient.new(token).image(id) }
      send_data bytes, type: mime, disposition: "inline"
    end

    private

    def load_account = @app = App.wechat_official_accounts.find(params[:app_id])
    def configuration = @config ||= Notifications::AccountConfiguration.new(@app)

    def existing_menu_text
      menu = @app.official_account_menu
      index = Integer(params[:menu_index].to_s, exception: false)
      unless menu && menu.revision.to_s == params[:menu_revision] && index && index >= 0
        raise ActiveRecord::RecordNotFound
      end
      nodes = menu.buttons.flat_map { |entry| [ entry, *entry.fetch("sub_button", []) ] }
      node = nodes[index] if index < nodes.length
      raise ActiveRecord::RecordNotFound unless node && node["type"] == "text" && node["value"].present?
      { "name" => node.fetch("name"), "messages" => [
        { "id" => SecureRandom.uuid, "type" => "text", "content" => { "text" => node.fetch("value") } }
      ] }
    end

    def prepare_editor
      @input = { id: params[:id], revision: configuration.revision, impact_revision: params[:id] ? configuration.impact_revision(params[:id]) : nil,
        qrcode_id: params[:qrcode_id], scope: params[:qrcode_id].present? || params[:inline] == "1" ? "only" : "all" }
      @impacts = params[:id] ? configuration.impacts(params[:id]) : []
      @variable_fields = Notifications::ReplyVariables::FIELDS
      @variable_examples = Notifications::ReplyVariables.examples(@app)
      @targets = App.wechat_mini_programs.order(:nickname, :id)
      render :edit
    end

    def save_reply
      input = params.require(:reply_content).permit(:name, :send_interval, :revision, :impact_revision, :scope, :qrcode_id,
        messages: [ :id, :type, :proof, { content: [ :text, :title, :appid, :pagepath, :thumb_media_id ] } ]).to_h
      input["id"] = params[:id] if params[:id]
      result = configuration.save_reply!(input, actor: current_admin, request: request)
      render json: result
    end

    def failed(error)
      feedback = error.is_a?(Notifications::FieldError) ? error.feedback : { error: error.message }
      render json: feedback, status: :unprocessable_content
    end
  end
end
