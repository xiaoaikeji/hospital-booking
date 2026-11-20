module WechatPlatform
  class AppProfile
    def initialize(app)
      @app = app
    end

    def read = with_client { |client| read_for_app(client) }

    def check_nickname(value)
      raise Error, "请输入 1～60 个字符的待检测名称" unless value.length.between?(1, 60)
      with_client { |client| client.check_nickname(value) }
    end

    def update_signature(value, revision:)
      raise Error, "简介需要 4～120 个字符" unless value.length.between?(4, 120)
      change("signature", revision) do |client, current|
        raise Error, "微信当前简介与填写内容相同" if current["signature"] == value
        client.modify_signature(value)
      end
    end

    def update_head_image(file, revision:)
      upload = MediaUpload.new(file, as: :wechat_avatar).validate!
      type, filename = upload.content_type, upload.filename
      change("head_image", revision) do |client, _current|
        client.modify_head_image(client.upload_image(file, type, filename))
      end
    rescue MediaUpload::Invalid => error
      raise Error, error.message
    end

    def self.revision(app, field, info)
      Digest::SHA256.hexdigest([ app.appid, field, info.sort ].to_json)
    end

    private

    def with_client
      raise Error, "请先完成该微信小程序的平台授权" unless @app.code_capable? && @app.platform_authorized?
      AuthorizerToken.with_token(@app) { |token| yield Wechat::MiniProgramProfileClient.new(token) }
    end

    def read_for_app(client)
      data = client.basic_info
      raise Error, "微信返回的 AppID 与当前应用不一致" if data["appid"].present? && data["appid"] != @app.appid
      data
    end

    def change(field, revision)
      with_client do |client|
        @app.with_lock do
          current = read_for_app(client).fetch("#{field}_info", {})
          unless self.class.revision(@app, field, current) == revision
            raise Error, "微信账号资料已变化，请核对最新资料再提交"
          end
          yield client, current
        end
      end
    end
  end
end
