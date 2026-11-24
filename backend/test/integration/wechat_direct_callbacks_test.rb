require "test_helper"
require "sidekiq/testing"
require_relative "../support/wechat_http_test"

class WechatDirectCallbacksTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include WechatHttpTest

  setup do
    install_wechat_stubs
    @admin = Admin.create!(username: "callback_owner", role: "super_admin")
    sign_in @admin
    @a, @b = %w[A B].map do |suffix|
      configure_account(App.create!(provider: "wechat", app_type: "official_account", appid: "wxLobby#{suffix}"))
    end
  end
  teardown { remove_wechat_stubs }

  def url_for_account(app) = api_wechat_official_account_messages_path(appid: app.appid)

  test "服务器握手、签名、内层接收方和加密包尾均绑定到独立公众号" do
    timestamp = Time.current.to_i.to_s
    nonce = "sample"
    signature = Digest::SHA1.hexdigest([@a.callback_token, timestamp, nonce].sort.join)
    query = { timestamp: timestamp, nonce: nonce, signature: signature, echostr: "wechat-challenge" }
    get url_for_account(@a), params: query
    assert_response :success
    assert_equal "wechat-challenge", response.body
    get url_for_account(@b), params: query
    assert_response :forbidden
    get url_for_account(@a), params: query.merge(timestamp: 12.hours.ago.to_i)
    assert_response :forbidden
    challenge = Nokogiri::XML(Wechat::MessageCrypto.new(AppConfiguration.new(@a).callback_credentials!).encrypt("encrypted-challenge"))
    get url_for_account(@a), params: { timestamp: challenge.at_xpath("//TimeStamp").text, nonce: challenge.at_xpath("//Nonce").text,
      msg_signature: challenge.at_xpath("//MsgSignature").text, echostr: challenge.at_xpath("//Encrypt").text }
    assert_response :success
    assert_equal "encrypted-challenge", response.body

    source = { "ToUserName" => @a.wechat_original_id, "FromUserName" => "sample-follower", "CreateTime" => timestamp,
      "Event" => "SCAN", "MsgType" => "event" }
    xml = source.to_xml(root: "xml", skip_types: true)
    assert_no_difference("OfficialAccountCallback.count") do
      signed_push(url_for_account(@b), xml)
      assert_response :forbidden
      signed_push(url_for_account(@a), xml, frame_appid: @b.appid)
      assert_response :forbidden
      signed_push(url_for_account(@a), source.merge("ToUserName" => @b.wechat_original_id).to_xml(root: "xml", skip_types: true))
      assert_response :forbidden
      post url_for_account(@a), params: xml, headers: { "CONTENT_TYPE" => "text/xml" }
      assert_response :forbidden
      @a.update!(status: "disabled")
      signed_push(url_for_account(@a), xml)
      assert_response :forbidden
    end
  end

  test "超管按公众号更新回调，密文落库、日志只含字段名，低权限直接读写被拒绝" do
    value = "LobbyNewToken"
    revision = AppConfiguration.new(@a).revision
    get edit_admins_app_path(@a)
    assert_response :success
    assert_match(/no-store/, response.headers["Cache-Control"])
    assert_select "#app_callback_token[type=text][data-write-only][autocomplete=off]:not([value]), #app_callback_encoding_aes_key[type=text][data-write-only][autocomplete=off]:not([value])", count: 2
    [ @a.callback_token, @a.callback_encoding_aes_key, @a.appsecret ].each { |secret| assert_not_includes response.body, secret }
    @stubs.post("/cgi-bin/stable_token") { response_for(access_token: "demo", expires_in: 7200) }
    patch admins_app_path(@a), params: { app: { revision: revision, callback_token: value } }
    assert_redirected_to admins_app_path(@a)
    assert_equal value, @a.reload.callback_token
    assert_not_includes @a.callback_token_before_type_cast, value
    assert_not_includes @a.callback_encoding_aes_key_before_type_cast, @a.callback_encoding_aes_key
    log = Log.where(action: "app.update", target_type: "App", target_id: @a.id).last
    assert_equal ["callback_token"], log.details.fetch("fields")
    assert_not_includes log.details.to_json, value
    patch admins_app_path(@a), params: {app: {revision: revision, callback_token: "stale"}}
    assert_response :unprocessable_content
    assert_not_includes response.body, value
    assert_equal value, @a.reload.callback_token
    assert_not_equal value, @b.reload.callback_token
    %w[operator customer_service].each do |role|
      sign_in Admin.create!(username: "lobby_#{role}", role: role)
      get edit_admins_app_path(@a)
      assert_response :forbidden
      assert_not_includes response.body, value
      patch admins_app_path(@a), params: {app: {revision: AppConfiguration.new(@a).revision, callback_token: "other"}}
      assert_response :forbidden
      get edit_admins_system_settings_wecom_notifications_path
      assert_response :forbidden
      patch admins_system_settings_wecom_notifications_path, params: {notification_settings: {webhook_key: "different-test-key"}}
      assert_response :forbidden
    end
  end

  test "回调校验失败的固定原因可见，附加凭据的历史原因只显示摘要" do
    reason = "请核对公众号原始 ID、回调 Token 和消息加解密密钥"
    previous = @a.appsecret
    draft = "draft-app-secret-fixture"
    patch admins_app_path(@a), params: { app: {
      revision: AppConfiguration.new(@a).revision, appsecret: draft, callback_token: "invalid token" } }
    assert_response :unprocessable_content
    assert_includes response.body, reason
    [ previous, draft ].each { |value| assert_not_includes response.body, value }
    assert_equal previous, @a.reload.appsecret
    failure = Log.where(action: "app.update", target_id: @a.id, status: "failed").sole
    assert_equal({ "reason" => reason }, failure.details)

    get admins_operation_log_path(failure)
    assert_select "dd", text: reason
    legacy = Log.create!(category: "app", action: "app.update", source: "admin", status: "failed",
      actor_type: "Admin", actor_id: @admin.id, details: { "reason" => "#{reason} #{previous}" })
    get admins_operation_log_path(legacy)
    assert_select "p", text: "历史详情已隐藏"
    assert_not_includes response.body, previous
  end

  test "代管读写路由和定时任务退出，直连、通知、页面配置及监控入口保留" do
    routes = Rails.application.routes
    legacy = {
      get: %w[/api/wechat/component/authorization/callback /api/wechat/apps/1/location_pictures/1 /admins/wechat_platform
        /admins/mini_program_releases /admins/code_templates /admins/illegal_records /admins/open_platform_accounts /admins/official_account_links],
      post: %w[/api/wechat/component/events /api/wechat/component/apps/wxExample/messages /admins/apps/1/authorization
        /admins/apps/1/releases /admins/apps/1/releases/2/submit /admins/apps/1/audits/2/publish /admins/apps/1/audits/2/withdraw
        /admins/apps/1/experiencers /admins/apps/1/categories /admins/apps/1/location_interface_applications /admins/apps/1/mini_program_links],
      patch: %w[/admins/apps/1/audits/2/sync /admins/apps/1/profile /admins/apps/1/server_domain /admins/apps/1/business_domain
        /admins/apps/1/privacy_setting /admins/apps/1/open_platform /admins/wecom_notification_content]
    }
    legacy.each do |method, paths|
      paths.each { |path| assert_raises(ActionController::RoutingError) { routes.recognize_path(path, method: method) } }
    end
    [admins_background_jobs_path, admins_notifications_path, admins_page_links_path].each do |path|
      assert routes.recognize_path(path, method: :get).fetch(:controller).start_with?("admins/")
    end
    assert_equal %w[notification_delivery mini_program_sessions_cleanup user_ip_location], YAML.safe_load_file(Rails.root.join("config/schedule.yml")).keys
  end

  test "大厅渠道码用自有密钥建码，扫码关注归因，被动应答及后续发送均有本账号记录" do
    Rails.cache.delete(direct_token_key(@a))
    @stubs.post("/cgi-bin/stable_token") do |env|
      body = JSON.parse(env.body)
      assert_equal [@a.appid, @a.appsecret], body.values_at("appid", "secret")
      response_for(access_token: "lobby-A", expires_in: 7200)
    end
    @stubs.post("/cgi-bin/qrcode/create") do |env|
      assert_equal "lobby-A", env.params.fetch("access_token")
      response_for(ticket: "local-lobby", url: "https://weixin.qq.com/q/local-lobby")
    end
    @stubs.get("/cgi-bin/user/info") { |env| response_for(openid: env.params.fetch("openid"), subscribe: 1, subscribe_scene: "ADD_SCENE_QR_CODE") }
    outbound = []
    @stubs.post("/cgi-bin/message/custom/send") { |env| outbound << [env.params["access_token"], JSON.parse(env.body)]; response_for(errcode: 0) }
    config = Notifications::AccountConfiguration.new(@a)
    reply = config.save_reply!({name: "大厅导诊", revision: config.revision,
      messages: ["请到二楼签到", "请携带预约凭证"].map.with_index { |line, i| {id: "line#{i}", type: "text", content: {text: line}} }}, actor: @admin)
    get new_admins_app_channel_qrcode_path(@a)
    form_key = css_select("input[name=form_key]").sole["value"]
    post admins_app_channel_qrcodes_path(@a), params: {form_key: form_key, official_account_qrcode: {name: "大厅"},
      reply_binding: {revision: config.revision, mode: "reply", reply_id: reply[:id]}}
    assert_redirected_to admins_channel_qrcodes_path(app_id: @a.id)
    code = OfficialAccountQrcode.where(app: @a, name: "大厅").sole
    xml = { ToUserName: @a.wechat_original_id, FromUserName: "lobby-patient", MsgType: "event", Event: "subscribe",
      EventKey: "qrscene_#{code.scene}", CreateTime: Time.current.to_i }.to_xml(root: "xml", skip_types: true)
    Sidekiq.testing!(:fake) do
      2.times { signed_push(url_for_account(@a), xml); assert_response :success }
      envelope = Nokogiri::XML(response.body)
      plain = Wechat::MessageCrypto.new(AppConfiguration.new(@a).callback_credentials!).decrypt(envelope.at_xpath("//Encrypt").text,
        timestamp: envelope.at_xpath("//TimeStamp").text, nonce: envelope.at_xpath("//Nonce").text, signature: envelope.at_xpath("//MsgSignature").text)
      assert_equal "请到二楼签到", Nokogiri::XML(plain).at_xpath("//Content").text
      WechatPlatform::FanEventWorker.drain
      assert_equal code.scene, OfficialAccountFan.for_app(@a).sole.qr_scene
      task = Notification.sole
      Notifications::DeliveryWorker.new.perform(task.id)
      task.reload
      assert_equal ["passive_prepared", "passive_response"], task.result_for("line0").values_at("provider_state", "stage")
      assert_equal ["sent", "channel_accepted"], task.result_for("line1").values_at("status", "stage")
      assert_equal [["lobby-A", "lobby-patient", "请携带预约凭证"]], outbound.map { |token, body| [token, body["touser"], body.dig("text","content")] }
      assert_equal 1, @a.official_account_callbacks.count
      assert_empty @b.official_account_callbacks
      assert_empty OfficialAccountFan.for_app(@b)
      get admins_notification_path(task)
      assert_response :success
      assert_includes response.body, "请携带预约凭证"
    end
  end
end
