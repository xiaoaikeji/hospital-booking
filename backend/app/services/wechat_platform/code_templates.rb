module WechatPlatform
  class CodeTemplates
    TYPES = { "normal" => "普通模板", "standard" => "标准模板" }.freeze
    AUDIT_STATES = %w[未提审 审核中 审核驳回 审核通过 提审中 提审失败].freeze
    attr_reader :platform

    def initialize
      @platform = ComponentToken.new
      @client = Wechat::CodeTemplateClient.new
    end

    def snapshot(key) = Rails.cache.read(cache_key(key))

    def refresh(key)
      rows = platform.with_token { |token| key == :drafts ? @client.drafts(token) : @client.templates(token) }
      id = key == :drafts ? "draft_id" : "template_id"
      rows = rows.sort_by { |row| -row.fetch(id).to_i }
      Rails.cache.write(cache_key(key), rows, expires_in: 7.days)
      rows
    end

    def upload_attributes(input)
      id = input.fetch(:template_id, "").to_s
      raise Error, "请填写数字模板 ID" unless id.match?(/\A\d+\z/)
      begin
        templates = refresh(:templates)
      rescue Error, HttpConnection::Unavailable, Wechat::BaseClient::Rejected
        unavailable = true
        templates = snapshot(:templates) || []
      end
      row = templates.find { |item| item["template_id"].to_s == id }
      raise Error, "微信模板库没有此模板，请刷新" unless row || unavailable
      attrs = input.slice(:template_id, :version, :description, :template_type).to_h.symbolize_keys
      if row && !unavailable
        current_type = row["template_type"].to_i == 1 ? "standard" : "normal"
        changed = {version: row["user_version"], description: row["user_desc"], template_type: current_type}.any? do |key, value|
          attrs[key].present? && value.present? && value != attrs[key]
        end
        raise Error, "微信模板资料已变更，请在弹窗刷新并重新选择" if changed
        attrs[:version] = row["user_version"] if row["user_version"].present?
        attrs[:description] = row["user_desc"] if row["user_desc"].present?
        attrs[:template_type] = current_type
      elsif row
        attrs[:version] = attrs[:version].presence || row["user_version"]
        attrs[:description] = attrs[:description].presence || row["user_desc"]
        attrs[:template_type] ||= row["template_type"].to_i == 1 ? "standard" : "normal"
      end
      attrs
    end

    def change!(action, id:, actor:, request:, type: nil)
      details = { (action == "add" ? :draft_id : :template_id) => id.to_s, template_type: type }.compact
      raise Error, "编号无效" unless id.to_s.match?(/\A\d+\z/)
      raise Error, "请选择模板类型" if action == "add" && !TYPES.key?(type)
      platform.with_token do |token|
        action == "add" ? @client.add(token, id.to_i, type) : @client.remove(token, id.to_i)
      end
      remote = true
      Rails.cache.delete(cache_key(:templates))
      Log.record!(category: "wechat", action: "wechat.template_#{action}", actor: actor, request: request, details: details)
    rescue Error, HttpConnection::Unavailable, Wechat::BaseClient::Rejected, ActiveRecord::ActiveRecordError => error
      reason = remote ? "微信已确认，操作审计未保存，请先刷新模板库" : error.message
      Log.record!(category: "wechat", action: "wechat.template_#{action}", actor: actor, request: request,
        status: "failed", details: details.merge(reason: reason))
      raise Error, reason
    end

    private

    def cache_key(kind) = "wechat/component/#{platform.config[:appid]}/code_templates/#{kind}"
  end
end
