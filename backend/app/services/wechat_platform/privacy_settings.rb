module WechatPlatform
  class PrivacySettings
    class InvalidField < Error
      attr_reader :field, :entry_index

      def initialize(message, field:, entry_index: nil)
        super(message)
        @field = field
        @entry_index = entry_index
      end
    end

    OWNER_FIELDS = {
      "contact_email" => "联系邮箱", "contact_phone" => "联系电话", "contact_weixin" => "联系微信号",
      "contact_qq" => "联系 QQ", "notice_method" => "变更通知方式"
    }.freeze
    CONTACT_KEYS = OWNER_FIELDS.keys.excluding("notice_method").freeze

    Snapshot = Data.define(:app_id, :code_exist, :keys, :settings, :owner) do
      def declared
        settings.filter_map { |item| [item.fetch("privacy_key"), item["privacy_text"]] if item["privacy_text"].present? }.to_h
      end

      def missing = keys - declared.keys

      def revision
        Digest::SHA256.hexdigest([app_id, code_exist, keys.sort, declared.sort, owner.sort].to_json)
      end

      def entries
        labels = settings.index_by { |item| item["privacy_key"] }
        purposes = declared
        (purposes.keys | keys | labels.keys).map do |key|
          { "key" => key, "label" => labels.dig(key, "privacy_label"), "purpose" => purposes[key], "enabled" => purposes.key?(key) ? "1" : "0" }
        end
      end
    end

    attr_reader :last_read

    def initialize(app)
      @app = app
    end

    def read
      with_client { |client| snapshot(client.privacy) }
    end

    def apply!(input, actor:, request:)
      raise Error, "需要超级管理员权限" unless actor&.super_admin?
      with_client do |client|
        @app.with_lock do
          current = @last_read = snapshot(client.privacy)
          owner = current.owner.merge(input.fetch("owner", {}).slice(*OWNER_FIELDS.keys).transform_values { |v| v.to_s.strip }).compact_blank
          declarations = declaration_values(input.fetch("entries", {}).values)
          unless owner.values_at(*CONTACT_KEYS).any?(&:present?)
            raise InvalidField.new("请填写至少一种开发者联系方式", field: "contact")
          end
          if owner["notice_method"].blank?
            raise InvalidField.new("请填写隐私指引变更时的通知方式", field: "notice_method")
          end
          if owner["contact_email"].present? && !URI::MailTo::EMAIL_REGEXP.match?(owner["contact_email"])
            raise InvalidField.new("请检查联系邮箱的格式", field: "contact_email")
          end
          unless declarations == current.declared && owner == current.owner.compact_blank
            raise Error, "微信指引已变更，请重新读取后核对" unless input["revision"] == current.revision
            client.update_privacy(owner: owner, settings: declarations.map { |key, purpose| {privacy_key: key, privacy_text: purpose} })
          end
          WechatPlatform.log!(@app, "privacy_update", actor: actor, request: request, details: { declaration_count: declarations.size })
        end
      end
    rescue Error, HttpConnection::Unavailable, Wechat::BaseClient::Rejected => error
      WechatPlatform.log!(@app, "privacy_update", actor: actor, request: request, status: "failed", details: { reason: error.message })
      raise
    end

    private

    def declaration_values(entries)
      entries.each_with_index.each_with_object({}) do |(row, index), declared|
        next unless row["enabled"] == "1"
        key = row["key"].to_s.strip
        unless key.match?(/\A[A-Za-z][A-Za-z0-9_]*\z/)
          raise InvalidField.new("请填写微信隐私接口标识", field: "key", entry_index: index)
        end
        if declared.key?(key)
          raise InvalidField.new("隐私接口标识有重复，请检查", field: "key", entry_index: index)
        end
        text = row["purpose"].to_s.strip
        if text.blank?
          raise InvalidField.new("请填写已勾选声明项的实际用途", field: "purpose", entry_index: index)
        end
        declared[key] = text
      end
    end

    def with_client
      raise Error, "请选择已完成平台授权的微信小程序" unless @app.code_capable? && @app.platform_authorized?
      AuthorizerToken.with_token(@app) { |token| yield Wechat::MiniProgramSettingsClient.new(token) }
    end

    def snapshot(data)
      unless data.keys.intersect?(%w[code_exist privacy_list setting_list owner_setting])
        raise HttpConnection::Unavailable, "微信未返回开发版隐私指引，请重新读取"
      end
      owner, keys, settings = data.fetch("owner_setting", {}), data.fetch("privacy_list", []), data.fetch("setting_list", [])
      unless owner.is_a?(Hash) && keys.is_a?(Array) && keys.all?(String) && settings.is_a?(Array) &&
          settings.all? { |row| row.is_a?(Hash) && row["privacy_key"].is_a?(String) && row["privacy_key"].present? }
        raise HttpConnection::Unavailable, "微信隐私指引格式无效，请重新读取"
      end
      Snapshot.new(@app.id, data["code_exist"], keys.uniq, settings, owner)
    end
  end
end
