module Notifications
  module EventCatalog
    def self.definitions = @definitions ||= {}

    # 接入项目登记自己的事件与业务字段，不在渠道里判断科室、比赛或收件人。
    def self.register(key, label:, fields:)
      definitions[key] = { "label" => label, "fields" => fields.deep_stringify_keys }
    end

    def self.fetch(key) = definitions.fetch(key) { raise Error, "未登记的通知事件" }
  end
end
