module WechatPlatform
  class AuditScreenshot
    TYPES = %w[image/png image/jpeg image/gif image/webp].freeze

    def self.fetch(app, round, index)
      raise ActiveRecord::RecordNotFound unless round.app_id == app.id && index && index >= 0
      media = round.rejection_screenshots[index]
      raise ActiveRecord::RecordNotFound if media.blank?
      raise Error, "恢复此应用的平台授权后可查看截图。" unless app.code_capable? && app.platform_authorized?
      key = "apps/#{app.id}/audit_images/#{Digest::SHA256.hexdigest(media)}"
      Rails.cache.fetch(key, expires_in: 1.day) do
        buffer = AuthorizerToken.with_token(app) { |token| Wechat::MiniProgramCodeClient.new(token).audit_screenshot(media) }
        type = Marcel::MimeType.for(StringIO.new(buffer))
        raise Error, "微信未返回有效图片，请稍后重试。" unless buffer.bytesize <= 10.megabytes && TYPES.include?(type)
        { bytes: buffer, type: type }
      end
    rescue Wechat::BaseClient::Rejected => error
      raise Error, "微信素材已失效，无法读取这张截图。" if error.code == 40007
      raise
    end
  end
end
