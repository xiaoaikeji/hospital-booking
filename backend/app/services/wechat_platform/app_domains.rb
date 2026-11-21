module WechatPlatform
  class AppDomains
    class InvalidField < Error
      attr_reader :field

      def initialize(field, message)
        @field = field
        super(message)
      end
    end

    SERVER = {
      "requestdomain" => ["request 合法域名", "https"], "uploaddomain" => ["uploadFile 合法域名", "https"],
      "downloaddomain" => ["downloadFile 合法域名", "https"], "wsrequestdomain" => ["socket 合法域名", "wss"],
      "udpdomain" => ["UDP 合法域名", "udp"], "tcpdomain" => ["TCP 合法域名", "tcp"]
    }.freeze
    FIELDS = { "server" => SERVER, "business" => { "webviewdomain" => ["web-view 业务域名", "https"] } }.freeze
    TITLES = { "server" => "服务器域名", "business" => "业务域名" }.freeze
    # 微信允许服务器域名带端口；业务域名不接受端口，包含显式的 :443。
    ORIGIN = %r{\A(?<scheme>https|wss|udp|tcp)://(?<host>[a-z0-9.-]+)(?::(?<port>[0-9]+))?/?\z}i
    DNS_LABEL = /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/i

    WECHAT_HINTS = {
      85017 => "请核对是否有变更，以及第三方平台已登记的服务器域名",
      85018 => "请先在微信第三方平台登记该服务器域名",
      89029 => "业务域名数量超过微信上限",
      89231 => "个人小程序不支持设置业务域名"
    }.freeze

    def initialize(app)
      @app = app
      @checked = {}
    end

    def snapshot
      FIELDS.keys.index_with do |kind|
        @checked[kind] || with_client { |client| domain_snapshot(kind, read(client, kind)) }
      rescue Error, HttpConnection::Unavailable, Wechat::BaseClient::Rejected => error
        { error: error.message }
      end
    end

    def self.defaults(kind)
      FIELDS.fetch(kind).keys.filter_map do |field|
        value = ENV["WECHAT_DOMAIN_DEFAULT_#{field.upcase}"]
        [field, value.lines.map(&:strip).compact_blank.uniq] if value.present?
      end.to_h
    end

    def replace!(kind, texts:, clear:, expected:)
      with_client do |client|
        @app.with_lock do
          current = read(client, kind)
          @checked[kind] = domain_snapshot(kind, current)
          raise Error, "微信域名已变化，请重新核对当前值" unless expected == @checked[kind][:revision]
          updated = replacement(kind, current, texts, clear)
          changed = updated.keys.select { |key| updated[key].sort != current.fetch(key).sort }
          client.replace(kind, updated) if changed.any?
          changed
        end
      end
    rescue Wechat::BaseClient::Rejected => error
      hint = WECHAT_HINTS[error.code]
      raise Error, [error.message, hint].compact.join("。"), cause: nil
    rescue HttpConnection::Unavailable => error
      raise Error, "#{error.message}。请刷新微信当前域名，核实后再决定是否保存。", cause: nil
    end

    private

    def replacement(kind, current, texts, clear)
      current.dup.tap do |updated|
        FIELDS.fetch(kind).each do |field, (label, _scheme)|
          entries = texts[field].to_s.lines.map(&:strip).compact_blank.uniq
          if clear.include?(field)
            raise InvalidField.new(field, "请先删除#{label}编辑框中的内容，再确认清空") if entries.any?
            updated[field] = []
          elsif entries.any? && entries.sort != current[field].sort
            updated[field] = validate(entries, kind, field)
          end
        end
      end
    end

    def read(client, kind)
      data = client.read(kind)
      keys = FIELDS.fetch(kind).keys
      unless keys.any? { |key| data.key?(key) } && keys.all? { |key| !data.key?(key) || (data[key].is_a?(Array) && data[key].all?(String)) }
        raise Error, "微信未返回可核实的#{TITLES.fetch(kind)}，请重新读取"
      end
      keys.index_with { |key| Array(data[key]).uniq }
    end

    def with_client
      AuthorizerToken.with_token(@app) { |token| yield Wechat::MiniProgramDomainClient.new(token) }
    end

    def revision(kind, domains)
      Digest::SHA256.hexdigest([@app.id, kind, domains.transform_values(&:sort)].to_json)
    end

    def domain_snapshot(kind, domains) = { domains: domains, revision: revision(kind, domains) }

    def validate(values, kind, field)
      label, scheme = FIELDS.fetch(kind).fetch(field)
      limit = kind == "business" ? 300 : 200
      raise InvalidField.new(field, "#{label}最多可设置 #{limit} 条") if values.size > limit
      values.map do |value|
        match = ORIGIN.match(value)
        host = match && match[:host].downcase
        labels = host.to_s.split(".", -1)
        unless match && match[:scheme].downcase == scheme && labels.size >= 2 && host.size <= 253 &&
            labels.all? { |part| DNS_LABEL.match?(part) } && labels.last.match?(/[a-z]/) &&
            !(kind == "server" && host == "api.weixin.qq.com")
          raise InvalidField.new(field, "#{label}请填写 #{scheme}:// 开头的合法域名，不能包含路径、参数或 IP 地址")
        end
        port = match[:port]
        raise InvalidField.new(field, "业务域名不能包含端口") if kind == "business" && port
        raise InvalidField.new(field, "#{label}的端口号无效") if port && !port.to_i.between?(1, 65535)
        "#{scheme}://#{host}#{":#{port}" if port}"
      end.uniq
    end
  end
end
