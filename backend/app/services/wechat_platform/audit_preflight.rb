module WechatPlatform
  class AuditPreflight
    Note = Data.define(:text, :warning)

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
      current = PrivacySettings.new(@app).read
      return Note.new("隐私指引尚未声明：#{current.missing.join('、')}，建议先完善。", true) if current.missing.any?
      unless current.owner.values_at(*PrivacySettings::CONTACT_KEYS).any?(&:present?)
        return Note.new("开发版隐私指引缺少主体联系方式，建议先完善。", true)
      end
      return Note.new("开发版隐私指引缺少变更通知方式，建议先完善。", true) if current.owner["notice_method"].blank?
      Note.new("已读取开发版隐私指引。", false)
    rescue Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable => error
      Note.new("隐私指引暂不可读（#{error.message}），仍可提交。", true)
    end
  end
end
