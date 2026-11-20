module WechatPlatform
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
        if app.app_authorization
          raise Error, "请先恢复该小程序的平台授权" unless app.platform_authorized?
        else
          secret, = AppConfiguration.new(app).credential
          raise Error, "请先配置该小程序 AppSecret 或完成平台授权" if secret.blank?
        end
      else
        raise Error, "请选择扫码目标"
      end
      app
    rescue AppConfiguration::Invalid => error
      raise Error, error.message
    end

    def self.fetch(**target)
      app = validate!(**target)
      if target[:target_kind] == "official_account"
        return OfficialAccountQrcode.where(app_id: app.id).find(target[:official_account_qrcode_id]).png
      end
      path = [ target[:page_path], target[:page_query].presence ].compact.join("?")
      auth = app.app_authorization
      secret, = AppConfiguration.new(app).credential unless auth
      revision = auth ? auth.cache_key_with_version : Digest::SHA256.hexdigest(secret)
      key = "apps/#{app.id}/wechat/poster_code/#{Digest::SHA256.hexdigest([ app.appid, revision, path ].to_json)}"
      Rails.cache.fetch(key, expires_in: 30.days) do
        client = Wechat::MiniProgramQrcodeClient.new
        if auth
          AuthorizerToken.with_token(app) { |token| client.page(token, path: path) }
        else
          token = Wechat::CredentialClient.new.access_token(app.appid, secret)
          client.page(token, path: path)
        end
      end
    rescue AppConfiguration::Invalid => error
      raise Error, error.message
    end
  end
end
