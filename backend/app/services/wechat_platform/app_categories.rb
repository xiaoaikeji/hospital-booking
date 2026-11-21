module WechatPlatform
  class AppCategories
    EVENTS = %w[wechat.category_add wechat.category_delete wechat.category_verify].freeze

    def initialize(app, actor: nil, request: nil)
      @app, @actor, @request = app, actor, request
    end

    def page
      outstanding = acceptances.to_a
      data = with_client(&:category_settings)
      used = data.fetch("categories").map { |row| [ row["first"].to_i, row["second"].to_i ] }
      observed, waiting = outstanding.partition { |entry| used.include?([ entry.first_category, entry.second_category ]) }
      acceptances.where(id: observed.map(&:id)).delete_all if observed.any?
      used = (used + waiting.map { |entry| [ entry.first_category, entry.second_category ] }).map { |ids| ids.join("-") }
      last_event = Log.where(target_type: "App", target_id: @app.id, source: "system", action: "wechat.category_audit")
        .order(Arel.sql("(details ->> 'occurred_at')::bigint DESC"), id: :desc).first
      result = { settings: data, waiting: waiting, options: [], blocked: quota_blocker(data), revision: revision(data), pending: unresolved, last_event: last_event }
      begin
        result[:options] = CategoryCatalog.for(@app) { with_client(&:catalog) }.options(added: used)
      rescue Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable => error
        result[:blocked] ||= "可添加的类目暂不可读：#{error.message}"
      end
      result
    end

    def awaiting_verification? = unresolved.present?

    def category_name(first, second)
      configured = read_category do
        with_client(&:category_settings).fetch("categories").find do |row|
          row["first"].to_s == first.to_s && row["second"].to_s == second.to_s
        end&.values_at("first_name", "second_name")
      end
      return configured.join(" / ") if configured&.all?(&:present?)

      catalog = read_category do
        CategoryCatalog.for(@app) { with_client(&:catalog) }.find(first, second)&.values_at("first_name", "name")
      end
      names = [configured&.first.presence || catalog&.first.presence, configured&.last.presence || catalog&.last.presence]
      "#{names.first || first} / #{names.last || second}" if names.any?
    end

    def add!(input)
      mutate("category_add", input) do |data, client|
        raise Error, quota_blocker(data) if quota_blocker(data)
        raise Error, "本应用已设置此类目，请刷新" if configured?(data)
        raise Error, "微信已受理该类目，正在等待列表更新" if acceptance.exists?
        category = CategoryCatalog.for(@app) { client.catalog }.find(@first, @second) || raise(Error, "请选择有效的一级和二级分类")
        plans = category["plans"]
        index = plans.size == 1 ? 0 : Integer(input[:plan].to_s, 10, exception: false)
        raise Error, "请选择资质方案" if plans.any? && (!index || index < 0 || index >= plans.size)
        files = Array(plans[index || 0]).each_with_index.map do |item, n|
          file = indexed(input, :certificates, n)
          begin
            upload = MediaUpload.new(file, as: :wechat_certificate).validate!
          rescue MediaUpload::Invalid => error
            raise Error, "#{item['name']}：#{error.message}"
          end
          [ item.fetch("name"), file, upload.content_type, upload.filename, expiry(input, n) ]
        end
        # 先校验所有资质，再上传临时素材。临时素材失败不代表类目申请已提交。
        certificates = files.map do |name, file, type, filename, validity|
          { key: name, value: client.upload_image(file, type, filename) }.merge(validity)
        end
        urgent = files.any? && input[:audit_urgent] == "1"
        dispatch! { client.add(@first, @second, certificates, urgent) }
      end
    end

    def remove!(input)
      mutate("category_delete", input) do |data, client|
        raise Error, "类目已变更，请刷新" unless configured?(data)
        dispatch! { client.remove(@first, @second) }
      end
    end

    def verify!(input)
      require_admin!
      locked do
        if input[:acceptance_id].present?
          entry = acceptances.find_by(id: input[:acceptance_id])
          raise Error, "请核实当前待更新类目" unless entry && input[:confirmed] == "1"
          @first, @second = entry.first_category, entry.second_category
          raise Error, "微信列表中已存在该类目，请刷新查看" if configured?(with_client(&:category_settings))
          WechatCategoryAcceptance.transaction do
            entry.destroy!
            record("category_verify", "success", acceptance_id: entry.id, outcome: "rejected_or_removed")
          end
          next
        end
        previous = unresolved
        unless previous && previous.id.to_s == input[:operation_id] && input[:confirmed] == "1"
          raise Error, "请核实当前待确认的类目操作"
        end
        @first, @second = previous.details.values_at("first", "second")
        applied = configured?(with_client(&:category_settings)) == (previous.action == "wechat.category_add")
        expected = applied ? "applied" : "not_applied"
        raise Error, "登记结果与微信当前类目列表不一致，请核实后再试" unless input[:outcome] == expected
        WechatCategoryAcceptance.transaction do
          acceptance.delete_all if applied && previous.action == "wechat.category_delete"
          record("category_verify", "success", operation_id: previous.id, outcome: expected)
        end
      end
    rescue Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable => error
      record("category_verify", "failed", reason: error.message) if @actor&.super_admin?
      raise
    end

    private

    def read_category
      yield
    rescue Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable
      nil
    end

    def mutate(action, input)
      require_admin!
      @action = action
      @first, @second = %i[first second].map { |key| Integer(input[key].to_s, 10, exception: false) }
      locked do
        raise Error, "请先核实上次服务类目操作" if unresolved
        raise Error, "服务类目编号无效" unless @first&.positive? && @second&.positive?
        with_client do |client|
          data = client.category_settings
          raise Error, "微信类目或额度已变化，请刷新后重新选择" unless revision(data) == input[:revision]
          yield data, client
        end
      end
    rescue Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable => error
      # 待核实意图由 started 表示，失败审计不会清除它。
      record(action, "failed", **{ reason: error.message, operation_id: @confirmed_failure }.compact) if @actor&.super_admin?
      raise
    end

    def dispatch!
      intent = record(@action, "started")
      begin
        yield
      rescue Wechat::BaseClient::Rejected => error
        if error.code == -1
          raise Error, "微信服务繁忙，类目操作结果待核实"
        end
        @confirmed_failure = intent.id
        raise Error, "资质图片已经失效，请重新提交" if error.code == 40007
        raise
      rescue HttpConnection::Unavailable
        raise Error, "微信暂未确认类目操作，请回服务类目页核实"
      end
      WechatCategoryAcceptance.transaction do
        if @action == "category_add"
          acceptance.first_or_create!
        else
          acceptance.delete_all
        end
        record(@action, "success", operation_id: intent.id)
      end
    rescue ActiveRecord::ActiveRecordError
      raise Error, "类目操作未能完整登记，请刷新并核实微信当前类目"
    end

    def with_client
      raise Error, "请先完成目标小程序的平台授权" unless @app.code_capable? && @app.platform_authorized?
      AuthorizerToken.with_token(@app) { |token| yield Wechat::MiniProgramCategoryClient.new(token) }
    end

    def require_admin!
      raise Error, "需要超级管理员权限" unless @actor&.super_admin?
    end

    def configured?(data)
      data.fetch("categories").any? { |row| row["first"].to_i == @first && row["second"].to_i == @second }
    end

    def quota_blocker(data)
      limit, quota = data.values_at("category_limit", "quota")
      return "已达到 #{limit} 个服务类目上限" if limit && data["categories"].size >= limit.to_i
      "本月新增额度已用尽" if quota && quota.to_i <= 0
    end

    def indexed(input, key, n)
      values = input[key]
      values[n.to_s] if values.is_a?(ActionController::Parameters) || values.is_a?(Hash)
    end

    def expiry(input, n)
      return { is_permanent: 1 } if indexed(input, :expire_modes, n) == "permanent"
      raw = indexed(input, :expire_times, n).to_s
      raise Error, "请填写资质有效期或选择长期有效" unless raw.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      { expire_time: Date.iso8601(raw).in_time_zone("Asia/Shanghai").end_of_day.to_i }
    rescue Date::Error
      raise Error, "请填写有效日期"
    end

    def acceptances = WechatCategoryAcceptance.where(app_id: @app.id)
    def acceptance = acceptances.where(first_category: @first, second_category: @second)

    def history
      Log.where(target_type: "App", target_id: @app.id, category: "wechat", action: EVENTS)
    end

    def revision(data)
      summary = data["categories"].map { |row| row.values_at("first", "second", "audit_status").map(&:to_s) }.sort
      Digest::SHA256.hexdigest([ @app.id, summary, data["quota"], data["category_limit"], history.where(status: "success").maximum(:id) ].to_json)
    end

    def unresolved
      last = history.where(status: "started").order(id: :desc).first
      last if last && !history.where("details ->> 'operation_id' = ?", last.id.to_s).exists?
    end

    def record(action, status, **details)
      WechatPlatform.log!(@app, action, actor: @actor, request: @request, status: status, details: details.merge(first: @first, second: @second))
    end

    def locked
      App.connection_pool.with_connection do |connection|
        key = "hashtextextended('booking.wechat.category:#{Integer(@app.id)}', 0)"
        raise Error, "该应用正在处理服务类目操作，请稍后刷新" unless connection.select_value("SELECT pg_try_advisory_lock(#{key})")
        begin
          yield
        ensure
          connection.execute("SELECT pg_advisory_unlock(#{key})")
        end
      end
    end
  end
end
