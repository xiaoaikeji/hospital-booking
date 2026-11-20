module WechatPlatform
  class OfficialAccountMenus
    MEDIA = {
      "image" => [10.megabytes, %w[image/png image/jpeg image/gif image/bmp]],
      "voice" => [2.megabytes, %w[audio/mpeg audio/amr audio/wav audio/x-wav]],
      "video" => [10.megabytes, %w[video/mp4]]
    }.freeze

    def initialize(app, actor:, request:)
      @app, @actor, @request = app, actor, request
    end

    def publish!(buttons, revision, clear:)
      action("publish") do
        locked(revision) do |row|
          raise Error, "上次发布结果待核实，请先从微信读取" unless row.pending_buttons.nil?
          normalized = MenuButtons.new(@app, row.buttons).normalize(buttons)
          raise Error, "请明确确认清空公众号菜单" if normalized.empty? && !clear
          client do |api|
            row.update!(pending_buttons: normalized, revision: row.revision + 1)
            begin
              api.publish(MenuButtons.wire(normalized))
            rescue Wechat::BaseClient::Rejected
              row.update!(pending_buttons: nil, revision: row.revision - 1)
              raise
            end
            row.transaction do
              row.update!(buttons: normalized, pending_buttons: nil)
              log("publish", count: normalized.size)
            end
          end
        end
      end
    end

    def pull!(revision, accept: false)
      action("pull") do
        locked(revision) do |row|
          remote = client(&:current)
          prior = row.buttons + Array(row.pending_buttons)
          buttons = MenuButtons.new(@app, prior).from_wechat(remote)
          row.transaction do
            if !row.pending_buttons.nil? && MenuButtons.wire(buttons) != MenuButtons.wire(row.pending_buttons) && !(accept && row.observed_buttons == buttons)
              row.update!(observed_buttons: buttons, revision: row.revision + 1)
              log("pull", result: "mismatch")
              next :mismatch
            end
            row.update!(buttons: buttons, pending_buttons: nil, observed_buttons: nil, revision: row.revision + 1)
            log("pull", count: buttons.size)
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
      nodes = buttons.flat_map { |node| [node, *node.fetch("sub_button", [])] }
      raise ActiveRecord::RecordNotFound unless nodes.any? { |node| node["type"] == "media_id" && node["kind"] == "image" && node["media_id"] == id }
      client { |api| api.image(id) }
    end

    def upload!(file, kind)
      action("media") do
        limit, types = MEDIA[kind]
        raise Error, "请选择图片、音频或视频文件" unless types && file.respond_to?(:tempfile)
        raise Error, "文件超过 #{limit / 1.megabyte} MB" unless file.size.between?(1, limit)
        mime = Marcel::MimeType.for(file.tempfile)
        file.rewind
        raise Error, "文件格式与素材类型不匹配" unless types.include?(mime)
        ext = { "image/jpeg" => "jpg", "audio/mpeg" => "mp3", "audio/x-wav" => "wav" }.fetch(mime) { mime.split("/").last }
        filename = "#{Time.current.to_i}#{Digest::MD5.file(file.path).hexdigest.first(6)}.#{ext}"
        id = client { |api| api.upload(file, kind, mime, filename) }
        log("media", kind: kind)
        { media_id: id, kind: kind, label: File.basename(file.original_filename), proof: MenuButtons.proof(@app, "media_id", id) }
      end
    end

    private

    def client
      raise Error, "请先完成该公众号的平台授权" unless @app.reload.platform_authorized?
      AuthorizerToken.with_token(@app) { |token| yield Wechat::OfficialAccountMenuClient.new(token) }
    end

    def locked(revision)
      raise Error, "请先完成该公众号的平台授权" unless @app.reload.platform_authorized?
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
    rescue WechatPlatform::Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable => e
      log(name, status: "failed", reason: e.class.name, code: (e.code if e.respond_to?(:code)))
      raise
    end

    def log(name, status: "success", **details)
      Log.record!(category: "wechat", action: "wechat.menu_#{name}", actor: @actor, target: @app, request: @request, status: status, details: details.compact)
    end
  end
end
