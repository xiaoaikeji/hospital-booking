module WechatPlatform
  class MenuButtons
    MAX_TOP = 3
    MAX_SUB = 5
    FALLBACK_URL = "https://mp.weixin.qq.com"
    REFERENCES = { "click" => "key", "media_id" => "media_id", "article_id" => "article_id" }.freeze

    def initialize(app, previous)
      @app = app
      @previous = previous.flat_map { |node| [node, *node.fetch("sub_button", [])] }
    end

    def normalize(rows, depth: 0, prefix: [])
      limit = depth.zero? ? MAX_TOP : MAX_SUB
      raise Error, "菜单列表格式错误" unless rows.is_a?(Array)
      raise Error, "#{depth.zero? ? '一级菜单' : '子菜单'}最多 #{limit} 个" if rows.size > limit
      rows.each_with_index.map do |node, i|
        path = prefix + [i + 1]
        raise Error, "菜单结构无效" unless node.is_a?(Hash)
        name = node["name"].to_s.strip
        width = name.each_char.sum { |c| c.ascii_only? ? 1 : 2 }
        max = depth.zero? ? 8 : 16
        raise Error, "第 #{path.join(' / ')} 项的名称应为 1～#{max / 2} 个汉字或 #{max} 个字母" unless width.between?(1, max)
        if node.key?("sub_button")
          raise Error, "「#{name}」只能有两级菜单" unless depth.zero?
          children = normalize(node["sub_button"], depth: 1, prefix: path)
          raise Error, "「#{name}」请新增子菜单" if children.empty?
          { "name" => name, "sub_button" => children }
        else
          leaf(node, name)
        end
      end
    end

    def from_wechat(rows, depth = 0)
      raise HttpConnection::Unavailable, "微信返回的菜单结构不完整" unless rows.is_a?(Array) && depth < 2
      rows.map do |node|
        raise HttpConnection::Unavailable, "微信返回的菜单缺少名称" unless node.is_a?(Hash) && node["name"].is_a?(String)
        if node.key?("sub_button")
          subs = node["sub_button"]
          subs = subs["list"] if subs.is_a?(Hash)
          next { "name" => node["name"], "sub_button" => from_wechat(subs, depth + 1) }
        end
        item = node.slice("name", "type", "url", "appid", "pagepath", "key", "media_id", "article_id")
        case item["type"]
        when "img", "voice"
          item.merge!("type" => "media_id", "media_id" => node["value"] || node["media_id"], "kind" => (item["type"] == "img" ? "image" : "voice"))
        when "article_id"
          item["article_id"] ||= node["value"]
        when "view", "click", "miniprogram", "media_id"
          # These menu types can be published through the API.
        else
          item["legacy"] = true
          item["value"] = node["value"].to_s if node["type"] == "text"
        end
        if (field = REFERENCES[item["type"]])
          previous = @previous.find { |old| old["type"] == item["type"] && old[field] == item[field] }
          item.merge!(previous.slice("label", "kind")) if previous
        end
        item
      end
    end

    def self.wire(rows)
      rows.map do |item|
        if item["sub_button"]
          { "name" => item["name"], "sub_button" => wire(item["sub_button"]) }
        else
          item.except("label", "kind", "proof")
        end
      end
    end

    def self.proof(app, type, id)
      Rails.application.message_verifier(:official_menu_resource).generate([app.id, type, id], expires_in: 1.day)
    end

    private

    def leaf(node, name)
      type = node["type"]
      item = { "type" => type, "name" => name }
      case type
      when "view", "miniprogram"
        url = node["url"].to_s.strip
        url = FALLBACK_URL if type == "miniprogram" && url.blank?
        uri = URI.parse(url) rescue nil
        raise Error, "「#{name}」请填写有效的 http 或 https 网址" unless uri.is_a?(URI::HTTP) && uri.host.present? && url.size <= 1000
        item["url"] = url
        if type == "miniprogram"
          appid, path = node.values_at("appid", "pagepath")
          existing = @previous.any? { |old| old["type"] == type && old["appid"] == appid }
          raise Error, "「#{name}」请选择本院小程序" unless appid.is_a?(String) && (existing || App.wechat_mini_programs.exists?(appid: appid))
          raise Error, "「#{name}」请填写小程序页面路径" unless path.is_a?(String) && path.present? && path.size <= 255
          item.merge!("appid" => appid, "pagepath" => path.strip)
        end
      when *REFERENCES.keys
        field = REFERENCES.fetch(type)
        id = node[field]
        previous = @previous.any? { |old| old["type"] == type && old[field] == id }
        proof = Rails.application.message_verifier(:official_menu_resource).verified(node["proof"].to_s) unless previous
        unless id.is_a?(String) && id.present? && (previous || (type != "click" && proof == [@app.id, type, id]))
          raise Error, "「#{name}」请使用本公众号的已有回复、素材或文章"
        end
        item[field] = id
        item.merge!(node.slice("label", "kind").transform_values { |v| v.to_s.first(150) }) if type != "click"
      else
        raise Error, "「#{name}」的微信原有动作无法通过菜单接口发布，请明确替换或删除该项"
      end
      item
    end
  end
end
