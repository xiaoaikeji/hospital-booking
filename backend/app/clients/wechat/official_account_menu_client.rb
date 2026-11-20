module Wechat
  class OfficialAccountMenuClient < BaseClient
    def initialize(token, **options)
      super(**options)
      @query = { access_token: token }
    end

    def current
      data = json(:get, "/cgi-bin/get_current_selfmenu_info", query: @query)
      return [] if data["is_menu_open"] == 0
      info = data["selfmenu_info"]
      buttons = info["button"] if info.is_a?(Hash)
      raise HttpConnection::Unavailable, "微信返回的菜单不完整" unless buttons.is_a?(Array)
      buttons
    end

    def publish(buttons)
      response = if buttons.empty?
        json(:get, "/cgi-bin/menu/delete", query: @query)
      else
        json(:post, "/cgi-bin/menu/create", query: @query, body: { button: buttons })
      end
      raise HttpConnection::Unavailable, "微信未确认菜单发布结果" unless response["errcode"] == 0
    end

    def articles(page)
      data = json(:post, "/cgi-bin/freepublish/batchget", query: @query, body: { offset: (page - 1) * 10, count: 10, no_content: 1 })
      total = Integer(data["total_count"].to_s, exception: false)
      items = data["item"] || ([] if total == 0)
      raise HttpConnection::Unavailable, "微信返回的文章列表不完整" unless total && total >= 0 && items.is_a?(Array) && items.all?(Hash)
      rows = items.map do |item|
        { article_id: required(item, "article_id"), label: item.dig("content", "news_item", 0, "title").presence || "无标题" }
      end
      { items: rows, pages: (total / 10.0).ceil }
    end

    def image(id)
      response = HttpConnection.request(@connection, :post, "/cgi-bin/material/get_material", query: @query, body: { media_id: id })
      bytes = response.body
      if response.headers["content-type"].to_s.include?("json") || bytes.lstrip.start_with?("{")
        checked(HttpConnection.json(response))
        raise HttpConnection::Unavailable, "微信未返回素材图片"
      end
      mime = Marcel::MimeType.for(StringIO.new(bytes))
      unless %w[image/png image/jpeg image/gif image/bmp].include?(mime) && bytes.bytesize <= 10.megabytes
        raise HttpConnection::Unavailable, "微信返回的图片格式无效"
      end
      [bytes, mime]
    end

    def upload(file, kind, mime, filename)
      part = Faraday::Multipart::FilePart.new(file.tempfile, mime, filename)
      body = { media: part }
      body[:description] = { title: filename, introduction: filename }.to_json if kind == "video"
      response = HttpConnection.request(@connection, :post, "/cgi-bin/material/add_material", query: @query.merge(type: kind), body: body)
      required(checked(HttpConnection.json(response)), "media_id")
    end
  end
end
