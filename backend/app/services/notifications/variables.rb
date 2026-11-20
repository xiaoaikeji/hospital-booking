module Notifications
  module Variables
    TOKEN = /(?<!\{)\{([A-Za-z_]\w*)\}(?!\})/

    def self.names(text) = text.to_s.scan(TOKEN).flatten.uniq

    def self.validate!(messages, fields:)
      Array(messages).each do |message|
        next unless message["type"] == "text"
        raise Error, "文字不能包含空字符" if message.dig("content", "text").to_s.include?("\u0000")
        unknown = names(message.dig("content", "text")) - fields.keys
        raise Error, "不可用的变量：#{unknown.map { |key| "{#{key}}" }.join('、')}" if unknown.any?
      end
    end

    def self.render(messages, fields:, data:, max_text_bytes: 2048)
      messages = messages.map(&:deep_stringify_keys)
      validate!(messages, fields: fields)
      values = data.stringify_keys
      messages.filter_map do |message|
        next message unless message["type"] == "text"
        text = message.dig("content", "text").to_s.gsub("\r\n", "\n")
        used = names(text)
        used.each do |key|
          missing = !values.key?(key) || values[key].nil? || (values[key].is_a?(String) && values[key].strip.empty?)
          raise Error, "通知数据缺少变量 {#{key}}" if missing && !fields.fetch(key).fetch("optional", false)
        end
        # 可选数据为空时省略该行，例如审核通过没有拒审原因。
        text = text.split("\n", -1).reject do |line|
          names(line).any? { |key| fields.fetch(key).fetch("optional", false) && values[key].to_s.strip.empty? }
        end.join("\n")
        text = text.gsub(TOKEN) do
          value = values[Regexp.last_match(1)]
          value.respond_to?(:strftime) ? value.strftime("%F %T") : value.to_s
        end.gsub(/\{\{([A-Za-z_]\w*)\}\}/, '{\1}')
        next if text.strip.empty?
        snapshot = message.deep_dup
        snapshot["truncated"] = true if text.bytesize > max_text_bytes
        snapshot["content"]["text"] = text.byteslice(0, max_text_bytes).scrub("")
        snapshot
      end
    end
  end
end
