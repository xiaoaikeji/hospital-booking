module WechatPlatform
  class LocationInterfaces
    class Unconfirmed < Error; end
    MAX_CONTENT = 300
    MAX_PICTURES = 10
    Entry = Struct.new(:data, :application) do
      LABELS = { 1 => "待申请", 2 => "无权限", 3 => "审核中", 4 => "申请失败", 5 => "已通过" }.freeze
      def name = data.fetch("api_name")
      def status
        value = data["status"]
        return 1 if value.nil? || value == ""
        Integer(value.to_s, 10, exception: false)
      end
      def label = LABELS.fetch(status, "未知")
      def review = [status, data["audit_id"].to_s, data["apply_time"].to_s]
      def description
        chinese = data["api_ch_name"].to_s.strip
        chinese.present? && chinese != name ? chinese : data["api_desc"]
      end

      def blocked_reason
        return "先核实上次申请" if application&.uncertain?
        return "已提交，等待微信列表更新" if application&.awaiting_list?(review)
        case status
        when 1, 4 then nil
        when 2 then "服务类目不符合开通条件"
        when 3 then "正在审核，不能重复提交"
        when 5 then "接口已开通"
        else "微信未确认是否可申请"
        end
      end
    end

    def initialize(app, actor: nil, request: nil)
      @app, @actor, @request = app, actor, request
    end

    def list
      rows = with_client(&:list)
      recent = @app.location_interface_applications.select("DISTINCT ON (api_name) *").order(:api_name, id: :desc).index_by(&:api_name)
      rows.map { |row| Entry.new(row, recent[row.fetch("api_name")]) }
    end

    def apply!(api_name, content, files, &picture_url)
      application = nil
      require_admin!
      raise Error, "请选择接口" unless api_name.length.between?(1, 100)
      raise Error, "请填写不超过 300 个字的申请原因" unless content.length.between?(1, MAX_CONTENT)
      raise Error, "补充图片最多 10 张" if files.size > MAX_PICTURES
      pictures = files.map { |file| LocationPicture.new(file) }
      locked do
        with_client do |client|
          entry = find_entry(client, api_name)
          raise Error, entry.blocked_reason if entry.blocked_reason
          application = prepare(entry, content, pictures)
          urls = application.pictures.attachments.map { |attachment| picture_url.call(application, attachment) }
          dispatch(client, application, urls)
        end
      end
    rescue Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable => error
      if application && error.is_a?(Wechat::BaseClient::Rejected)
        finish(application, "rejected", "location_apply", "failed", error_code: error.code)
      elsif @actor&.super_admin?
        details = { reason: error.message, application_id: application&.id }.compact
        details[:api_name] = api_name if api_name.match?(/\Awx\.[\w.]{1,96}\z/)
        log("location_apply", "failed", details)
      end
      raise
    end

    def verify!(id, observed_review, confirmed)
      require_admin!
      locked do
        application = @app.location_interface_applications.find(id)
        raise Error, "请先核对微信公众平台上的实际申请" unless confirmed == "1" && application.uncertain?
        entry = with_client { |client| find_entry(client, application.api_name) }
        raise Error, "接口状态已更新，请重新核对" unless entry.review.to_json == observed_review
        unchanged = entry.review == application.previous_review
        finish(application, unchanged ? "not_accepted" : "verified", "location_verify", "success")
      end
    rescue Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable => error
      log("location_verify", "failed", { reason: error.message }) if @actor&.super_admin?
      raise
    end

    private

    def find_entry(client, name)
      row = client.list.find { |item| item["api_name"] == name } || raise(Error, "当前小程序的微信列表没有此接口")
      Entry.new(row, @app.location_interface_applications.where(api_name: name).order(id: :desc).first)
    end

    def prepare(entry, content, pictures)
      blobs = []
      pictures.each { |picture| blobs << picture.upload! }
      LocationInterfaceApplication.transaction do
        application = @app.location_interface_applications.create!(api_name: entry.name, content: content,
          operator: @actor, previous_review: entry.review, state: "unconfirmed", pictures: blobs)
        log("location_apply", "started", { api_name: entry.name, application_id: application.id, pictures_count: blobs.size })
        application
      end
    rescue StandardError
      blobs.each { |blob| blob.purge unless blob.attachments.exists? }
      raise Error, "申请材料未能保存，请重新选择图片后提交"
    end

    def dispatch(client, application, urls)
      begin
        id = client.apply(application.api_name, application.content, urls)
      rescue HttpConnection::Unavailable
        raise Unconfirmed, "微信尚未确认受理结果，请先核实上次申请"
      rescue Wechat::BaseClient::Rejected => error
        raise Unconfirmed, "微信服务繁忙，请先核实上次申请" if error.code == -1
        raise
      end
      finish(application, "accepted", "location_apply", "success", audit_id: id)
      id
    rescue ActiveRecord::ActiveRecordError
      raise Unconfirmed, "申请结果未能保存，请先核对微信公众平台的申请单"
    end

    def finish(application, state, action, status, **changes)
      application.transaction do
        application.update!(state: state, **changes)
        log(action, status, { api_name: application.api_name, application_id: application.id, result: state }.merge(changes))
      end
    end

    def require_admin!
      raise Error, "需要超级管理员权限" unless @actor&.super_admin?
    end

    def with_client
      raise Error, "请先完成目标小程序的平台授权" unless @app.code_capable? && @app.platform_authorized?
      AuthorizerToken.with_token(@app) { |token| yield Wechat::MiniProgramLocationInterfaceClient.new(token) }
    end

    def log(action, status, details)
      WechatPlatform.log!(@app, action, actor: @actor, request: @request, status: status, details: details)
    end

    # Session lock spans the committed intent and the remote write. A crashed request remains visible for verification.
    def locked
      App.connection_pool.with_connection do |connection|
        key = "hashtextextended('booking.wechat.location:#{Integer(@app.id)}', 0)"
        raise Error, "该应用正在处理地理位置申请，请稍后刷新" unless connection.select_value("SELECT pg_try_advisory_lock(#{key})")
        begin
          yield
        ensure
          connection.execute("SELECT pg_advisory_unlock(#{key})")
        end
      end
    end
  end
end
