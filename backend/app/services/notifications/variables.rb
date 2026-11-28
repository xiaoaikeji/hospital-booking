module Notifications
  module Variables
    TOKEN = /(?<!\{)\{([A-Za-z_]\w*)\}(?!\})/

    def self.names(text) = text.to_s.scan(TOKEN).flatten.uniq

    def self.validate!(messages, fields:)
      Array(messages).each_with_index do |message, index|
        next unless message["type"] == "text"
        text = message.dig("content", "text").to_s
        if text.include?("\u0000")
          raise FieldError.new("文字不能包含空字符", field: "text", message_index: index)
        end
        unknown = names(text) - fields.keys
        if unknown.any?
          raise FieldError.new("不可用的变量：#{unknown.map { |key| "{#{key}}" }.join('、')}", field: "text", message_index: index)
        end
      end
    end

    def self.render(messages, fields:, data:, max_text_bytes: 2048, keep_partial_lines: false)
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
          keys = names(line)
          missing = keys.select { |key| fields.fetch(key).fetch("optional", false) && values[key].to_s.strip.empty? }
          missing.any? && (!keep_partial_lines || missing == keys)
        end.join("\n")
        text = text.gsub(TOKEN) do
          value = values[Regexp.last_match(1)]
          next "—" if keep_partial_lines && value.to_s.strip.empty?
          value.respond_to?(:strftime) ? value.strftime("%F %T") : value.to_s
        end.gsub(/\{\{([A-Za-z_]\w*)\}\}/, '{\1}')
        next if keep_partial_lines ? text.blank? : text.strip.empty?
        snapshot = message.deep_dup
        if max_text_bytes && text.bytesize > max_text_bytes
          snapshot["truncated"] = true
          text = text.byteslice(0, max_text_bytes).scrub("")
        end
        snapshot["content"]["text"] = text
        snapshot
      end
    end
  end
end
