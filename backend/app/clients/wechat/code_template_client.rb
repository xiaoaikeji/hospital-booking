module Wechat
  class CodeTemplateClient < BaseClient
    TYPES = { "normal" => 0, "standard" => 1 }.freeze
    FIELDS = %w[template_id draft_id template_type audit_status reason source_miniprogram source_miniprogram_appid user_version user_desc developer create_time].freeze

    def drafts(token) = list(token, "gettemplatedraftlist", "draft_list")
    def templates(token) = list(token, "gettemplatelist", "template_list")
    def add(token, id, type) = write(token, "addtotemplate", draft_id: id, template_type: TYPES.fetch(type))
    def remove(token, id) = write(token, "deletetemplate", template_id: id)

    private

    def list(token, path, key)
      rows = json(:get, "/wxa/#{path}", query: { access_token: token })[key]
      raise HttpConnection::Unavailable, "微信模板列表格式无效" unless rows.is_a?(Array) && rows.all?(Hash)
      id = key == "draft_list" ? "draft_id" : "template_id"
      raise HttpConnection::Unavailable, "微信模板编号无效" unless rows.all? { |row| row[id].to_s.match?(/\A\d+\z/) }
      rows.map { |row| row.slice(*FIELDS) }
    end

    def write(token, path, body)
      result = json(:post, "/wxa/#{path}", query: { access_token: token }, body: body)
      raise HttpConnection::Unavailable, "微信未确认模板操作，请刷新核实" unless result["errcode"] == 0
    end
  end
end
