module Wechat
  class MiniProgramCodeClient < BaseClient
    def initialize(token, **options)
      super(**options)
      @query = { access_token: token }
    end

    def upload(release)
      ext = { extEnable: true, extAppid: release.app.appid, ext: { provider: "wechat", appid: release.app.appid } }
      command("commit", template_id: release.template_id, ext_json: ext.to_json, user_version: release.version, user_desc: release.description)
    end

    def trial_qrcode
      response = HttpConnection.request(@connection, :get, "/wxa/get_qrcode", query: @query)
      return response.body if response.body.start_with?("\x89PNG".b, "\xff\xd8\xff".b)
      checked(HttpConnection.json(response))
      raise HttpConnection::Unavailable, "微信未返回体验码"
    end

    def submit(description)
      data = json(:post, "/wxa/submit_audit", query: @query, body: { version_desc: description })
      id = data["auditid"].to_s
      raise HttpConnection::Unavailable, "微信未返回有效审核单号" unless id.match?(/\A\d+\z/)
      id
    end

    def status(id) = json(:post, "/wxa/get_auditstatus", query: @query, body: { auditid: Integer(id, 10) })
    def version_info = json(:post, "/wxa/getversioninfo", query: @query, body: {})
    def withdraw
      data = json(:get, "/wxa/undocodeaudit", query: @query)
      raise HttpConnection::Unavailable, "微信未确认撤回结果" unless data.key?("errcode")
    end
    def publish = command("release", {})

    def latest_id
      id = required(json(:get, "/wxa/get_latest_auditstatus", query: @query), "auditid").to_s
      raise HttpConnection::Unavailable, "微信未返回有效审核单号" unless id.match?(/\A\d+\z/)
      id
    rescue Rejected => error
      raise unless error.code == 85058
      nil
    end

    private

    def command(path, body)
      data = json(:post, "/wxa/#{path}", query: @query, body: body)
      # 微信写接口以 errcode: 0 确认成功；空对象不能证明远端已执行。
      raise HttpConnection::Unavailable, "微信未确认操作结果" unless data.key?("errcode")
      data
    end
  end
end
