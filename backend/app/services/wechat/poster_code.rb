module Wechat
  # 只负责扫码目标与平台取码，调用方提供页面和参数，不写入预约、分发或邀请关系。
  class PosterCode
    def self.validate!(target_kind: nil, app_id: nil, official_account_qrcode_id: nil, page_path: nil, page_query: nil)
      app = App.wechat_accounts.find_by(id: app_id)
      raise Error, "请选择当前机构可用的微信应用" unless app&.accessible?
      case target_kind
      when "official_account"
        unless app.app_type == "official_account" && OfficialAccountQrcode.exists?(id: official_account_qrcode_id, app_id: app.id)
          raise Error, "请选择该公众号已有的渠道二维码"
        end
      when "mini_program"
        raise Error, "请选择微信小程序" unless app.code_capable?
        path = page_path.to_s
        unless path.match?(%r{\A[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*\z})
          raise Error, "请填写已发布页面路径，不带开头 / 或参数"
        end
        query = page_query.to_s
        if query.match?(/[\s#?]/) || [ path, query.presence ].compact.join("?").bytesize > 128
          raise Error, "页面和参数合计不能超过 128 字节，参数无需开头 ?"
        end
        AccessToken.credential!(app)
      else
        raise Error, "请选择扫码目标"
      end
      app
    end

    def self.fetch(**target)
      app = validate!(**target)
      if target[:target_kind] == "official_account"
        return OfficialAccountQrcode.where(app_id: app.id).find(target[:official_account_qrcode_id]).png
      end
      path = [ target[:page_path], target[:page_query].presence ].compact.join("?")
      prefix = AccessToken.cache_prefix(app, AccessToken.credential!(app))
      key = "#{prefix}/poster_code/#{Digest::SHA256.hexdigest(path)}"
      Rails.cache.fetch(key, expires_in: 30.days) do
        AccessToken.with_token(app) { |token| MiniProgramQrcodeClient.new.page(token, path: path) }
      end
    end
  end
end
