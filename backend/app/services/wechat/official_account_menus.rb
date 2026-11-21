module Wechat
  class OfficialAccountMenus
    def initialize(app, actor:, request:)
      @app, @actor, @request = app, actor, request
    end

    def publish!(buttons, revision, clear:)
      action("menu_publish") do
        locked(revision) do |row|
          raise Error, "上次发布结果待核实，请先从微信读取" unless row.pending_buttons.nil?
          normalized = MenuButtons.new(@app, row.buttons).normalize(buttons)
          raise Error, "请明确确认清空公众号菜单" if normalized.empty? && !clear
          client do |api|
            row.update!(pending_buttons: normalized, revision: row.revision + 1)
            begin
              api.publish(MenuButtons.wire(normalized))
            rescue Wechat::BaseClient::Rejected => error
              raise HttpConnection::Unavailable, "微信系统繁忙，请先核实本次菜单" if error.code == -1
              row.update!(pending_buttons: nil, revision: row.revision - 1)
              raise
            end
            row.transaction do
              row.update!(buttons: normalized, pending_buttons: nil)
              log("menu_publish", count: normalized.size)
            end
          end
        end
      end
    end

    def pull!(revision, accept: false)
      action("menu_pull") do
        locked(revision) do |row|
          remote = client(&:current)
          prior = row.buttons + Array(row.pending_buttons)
          buttons = MenuButtons.new(@app, prior).from_wechat(remote)
          row.transaction do
            if !row.pending_buttons.nil? && MenuButtons.wire(buttons) != MenuButtons.wire(row.pending_buttons) && !(accept && row.observed_buttons == buttons)
              row.update!(observed_buttons: buttons, revision: row.revision + 1)
              log("menu_pull", result: "mismatch")
              next :mismatch
            end
            row.update!(buttons: buttons, pending_buttons: nil, observed_buttons: nil, revision: row.revision + 1)
            log("menu_pull", count: buttons.size)
            :ok
          end
        end
      end
    end

    def articles(page)
      result = client { |api| api.articles(page) }
      result[:items].each { |item| item[:proof] = MenuButtons.proof(@app, "article_id", item[:article_id]) }
      result
    end

    def image(id)
      buttons = OfficialAccountMenu.find_by(app: @app)&.buttons || []
      nodes = buttons.flat_map { |node| [ node, *node.fetch("sub_button", []) ] }
      raise ActiveRecord::RecordNotFound unless nodes.any? { |node| node["type"] == "media_id" && node["kind"] == "image" && node["media_id"] == id }
      client { |api| api.image(id) }
    end

    def upload!(file, kind)
      purpose = { "image" => :menu_image, "voice" => :menu_voice, "video" => :menu_video }[kind]
      upload_media!(file, kind, purpose, "menu_media", "media_id")
    end

    def upload_card_cover!(file)
      upload_media!(file, "image", :reply_card_cover, "reply_card_cover_upload", "card_cover")
    end

    private

    def upload_media!(file, kind, purpose, event, proof_type)
      action(event) do
        raise Error, "请选择图片、音频或视频文件" unless purpose
        upload = MediaUpload.new(file, as: purpose).validate!
        mime, filename = upload.content_type, upload.filename
        id = client { |api| api.upload(file, kind, mime, filename) }
        log(event, kind: kind)
        { media_id: id, kind: kind, label: File.basename(file.original_filename), proof: MenuButtons.proof(@app, proof_type, id) }
      end
    end

    def client
      AccessToken.with_token(@app) { |token| yield Wechat::OfficialAccountMenuClient.new(token) }
    end

    def locked(revision)
      AccessToken.credential!(@app.reload)
      App.connection_pool.with_connection do |db|
        key = db.quote("booking.official_menu:#{@app.id}")
        lock = "hashtextextended(#{key}, 0)"
        raise Error, "该公众号正在处理菜单，请稍后核实" unless db.select_value("SELECT pg_try_advisory_lock(#{lock})")
        begin
          row = OfficialAccountMenu.find_or_create_by!(app: @app)
          raise Error, "菜单已变化，请刷新页面核对后再操作" unless revision == row.revision.to_s
          yield row
        ensure
          db.execute("SELECT pg_advisory_unlock(#{lock})")
        end
      end
    end

    def action(name)
      yield
    rescue MediaUpload::Invalid => error
      log(name, status: "failed", reason: error.class.name)
      raise Error, error.message
    rescue Wechat::Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable => e
      log(name, status: "failed", reason: e.class.name, code: (e.code if e.respond_to?(:code)))
      raise
    end

    def log(name, status: "success", **details)
      Wechat.log!(@app, name, actor: @actor, request: @request, status: status, details: details.compact)
    end
  end
end
