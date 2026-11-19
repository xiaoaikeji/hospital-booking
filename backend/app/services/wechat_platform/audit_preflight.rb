module WechatPlatform
  class AuditPreflight
    def initialize(app)
      @app = app
    end

    def messages
      [ privacy_message, category_message ]
    end

    def items
      approved.first(5).map do |row|
        { first_class: row["first_name"], second_class: row["second_name"], first_id: row["first"], second_id: row["second"] }
      end
    rescue Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable
      []
    end

    private

    def client = @client ||= Wechat::MiniProgramSettingsClient.new(AuthorizerToken.fetch(@app))
    def approved = client.categories.select { |row| row["audit_status"].to_i == 3 }

    def category_message
      names = approved.map { |row| [row["first_name"], row["second_name"]].compact_blank.join(" / ") }
      names.empty? ? "没有已通过的服务类目，建议先在微信完善。" : "已通过类目：#{names.join('、')}"
    rescue Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable => error
      "服务类目暂不可读（#{error.message}），仍可提交。"
    end

    def privacy_message
      data = client.privacy
      declared = Array(data["setting_list"]).pluck("privacy_key")
      missing = Array(data["privacy_list"]) - declared
      return "隐私指引尚未声明：#{missing.join('、')}，建议先完善。" if missing.any?
      return "开发版隐私指引缺少主体联系方式，建议先完善。" if data["owner_setting"].blank?
      "已读取开发版隐私指引。"
    rescue Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable => error
      "隐私指引暂不可读（#{error.message}），仍可提交。"
    end
  end
end
