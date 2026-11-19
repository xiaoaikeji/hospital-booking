module WechatPlatform
  class AuditPreflight
    Note = Data.define(:text, :warning)
    CONTACT_KEYS = %w[contact_email contact_phone contact_qq contact_weixin].freeze

    def initialize(app)
      @app = app
    end

    def messages = [ privacy_message, category_message ]

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
      return Note.new("没有已通过的服务类目，建议先在微信完善。", true) if names.empty?
      Note.new("已通过类目：#{names.join('、')}", false)
    rescue Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable => error
      Note.new("服务类目暂不可读（#{error.message}），仍可提交。", true)
    end

    def privacy_message
      data = client.privacy
      declared = Array(data["setting_list"]).pluck("privacy_key")
      missing = Array(data["privacy_list"]) - declared
      return Note.new("隐私指引尚未声明：#{missing.join('、')}，建议先完善。", true) if missing.any?
      owner = data["owner_setting"]
      unless owner.is_a?(Hash) && owner.values_at(*CONTACT_KEYS).any?(&:present?)
        return Note.new("开发版隐私指引缺少主体联系方式，建议先完善。", true)
      end
      Note.new("已读取开发版隐私指引。", false)
    rescue Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable => error
      Note.new("隐私指引暂不可读（#{error.message}），仍可提交。", true)
    end
  end
end
