require "test_helper"
require_relative "../support/wechat_http_test"
require "sidekiq/testing"

class ChannelQrcodesTest < ActionDispatch::IntegrationTest
  include WechatHttpTest
  include Devise::Test::IntegrationHelpers

  setup do
    install_wechat_stubs
    @admin = Admin.create!(username: "channels_admin", role: "super_admin")
    sign_in @admin
    @a, @b = %w[wx1111111111111111 wx2222222222222222].map do |id|
      app = App.create!(provider: "wechat", appid: id, app_type: "official_account", nickname: "院区#{id.last}")
      auth = app.create_app_authorization!(refresh_token: "test-only", original_id: "gh_#{id}")
      Rails.cache.write("apps/#{app.id}/channel_token", {value: id, revision: auth.updated_at.to_f})
      app
    end
    @calls = []
    @stubs.post("/cgi-bin/qrcode/create") do |env|
      json = JSON.parse(env.body)
      assert_equal "QR_LIMIT_STR_SCENE", json.fetch("action_name")
      scene = json.dig("action_info", "scene", "scene_str")
      @calls << [env.params["access_token"], scene]
      raise Faraday::TimeoutError if @timeout
      response_for(@reply || {ticket: "weixin-ticket", url: "http://weixin.qq.com/q/#{scene}"})
    end
  end
  teardown { remove_wechat_stubs }

  def form(app = @a)
    get new_admins_app_channel_qrcode_path(app)
    assert_response :success
    assert_select "input[name='official_account_qrcode[name]'][maxlength='60']:not([size])"
    css_select("input[name=form_key]").first["value"]
  end

  def submit(key, name, app = @a)
    post admins_app_channel_qrcodes_path(app), params: {form_key: key, official_account_qrcode: {name: name}}
  end

  test "带回复组和旧配置版本的原表单重放找回同一个已建渠道码" do
    config = Notifications::AccountConfiguration.new(@a)
    reply = config.save_reply!({ name: "活动回复", revision: config.revision,
      messages: [{ id: "welcome", type: "text", content: { text: "欢迎" } }] }, actor: @admin)
    key = form
    revision = css_select("input[name='reply_binding[revision]']").sole["value"]
    assert_select "#scan-mode option[value='reply']"
    assert_select "#channel-reply option[value=?]", reply[:id]
    original = { form_key: key, official_account_qrcode: { name: "原表单渠道" },
      reply_binding: { revision: revision, mode: "reply", reply_id: reply[:id] } }
    path = admins_app_channel_qrcodes_path(@a)
    post path, params: original
    assert_redirected_to admins_channel_qrcodes_path(app_id: @a.id)
    code = OfficialAccountQrcode.where(app: @a).sole
    assert_not_equal revision, config.revision
    assert_no_difference(["OfficialAccountQrcode.count", "Log.where(action: 'wechat.channel_qrcode_create', status: 'success').count"]) do
      post path, params: original
      assert_redirected_to admins_channel_qrcodes_path(app_id: @a.id)
    end
    assert_equal [[@a.appid, code.scene]], @calls
    assert_equal({ "mode" => "reply", "reply_id" => reply[:id] }, config.code_binding(code.id))
    assert_empty @b.official_account_callbacks
  end

  test "失败留在新增页保留输入，同表单只生成一个永久码，中文下载在撤销授权后仍可用" do
    key = form
    submit(key, "   ")
    assert_response :unprocessable_content
    assert_empty @calls
    @reply = {errcode: 48001}
    submit(key, " 门诊大厅 ")
    assert_response :unprocessable_content
    assert_equal "门诊大厅", css_select("input[name='official_account_qrcode[name]']").first["value"].strip
    assert_match(/48001/, response.body)
    assert_empty OfficialAccountQrcode.all
    @reply = nil
    @timeout = true
    submit(key, "门诊大厅")
    assert_response :unprocessable_content
    assert_select "input[name=form_key][value=?]", key
    @timeout = false
    assert_difference "OfficialAccountQrcode.count", 1 do
      2.times { submit(key, "门诊大厅") }
    end
    assert_redirected_to admins_channel_qrcodes_path(app_id: @a.id)
    code = OfficialAccountQrcode.sole
    assert_equal 3, @calls.size
    assert_equal [[@a.appid, code.scene]], @calls.uniq
    assert_not_equal "weixin-ticket", code.ticket_before_type_cast
    assert_equal 1, Log.where(action: "wechat.channel_qrcode_create", status: "success", target_id: @a.id).count
    assert_not_includes Log.where(action: "wechat.channel_qrcode_create").pluck(:details).to_s, "weixin-ticket"
    @a.app_authorization.update!(refresh_token: nil)
    get admins_channel_qrcodes_path(app_id: @a.id)
    assert_select "a[href=?]", new_admins_app_channel_qrcode_path(@a), count: 0
    get admins_app_channel_qrcode_path(@a, code, format: :png)
    assert_response :success
    assert_equal "image/png", response.media_type
    assert response.body.b.start_with?("\x89PNG".b)
    assert_includes response.headers["Content-Disposition"], ERB::Util.url_encode("门诊大厅.png")
    assert_equal 3, @calls.size
  end

  test "鉴权及签名按应用隔离，图片和直接写接口仅超管可用" do
    key = form
    submit(key, "调换公众号", @b)
    assert_response :unprocessable_content
    assert_empty @calls
    submit(key, "门诊")
    code = OfficialAccountQrcode.sole
    get admins_app_channel_qrcode_path(@b, code, format: :png)
    assert_response :not_found
    @b.app_authorization.update!(refresh_token: nil)
    get new_admins_app_channel_qrcode_path(@b)
    assert_redirected_to admins_channel_qrcodes_path(app_id: @b.id)
    mini = App.create!(provider: "wechat", appid: "wx3333333333333333")
    get admins_channel_qrcodes_path(app_id: mini.id)
    assert_response :not_found
    get new_admins_app_channel_qrcode_path(mini)
    assert_response :not_found
    %w[operator customer_service].each do |role|
      sign_in Admin.create!(username: "chan_#{role}", role: role)
      get admins_channel_qrcodes_path(app_id: @a.id)
      assert_response :forbidden
      get new_admins_app_channel_qrcode_path(@a)
      assert_response :forbidden
      submit(key, "越权")
      assert_response :forbidden
      get admins_app_channel_qrcode_path(@a, code, format: :png)
      assert_response :forbidden
    end
    assert_equal 1, @calls.size
  end

  test "拒绝不完整回执及临时码；令牌过期后同一表单可用新令牌继续" do
    key = form
    [{ticket: "t"}, {url: "http://weixin.qq.com/q/test"}, {ticket: "t", url: "http://weixin.qq.com/q/temp", expire_seconds: 3600},
      {ticket: "t", url: "https://example.invalid/other"}].each do |data|
      @reply = data
      submit(key, "院区")
      assert_response :unprocessable_content
      assert_empty OfficialAccountQrcode.all
    end
    @reply = {errcode: 42001}
    submit(key, "院区")
    assert_nil Rails.cache.read("apps/#{@a.id}/channel_token")
    assert Rails.cache.read("apps/#{@b.id}/channel_token")
    Rails.cache.write("apps/#{@a.id}/channel_token", {value: "fresh", revision: @a.app_authorization.updated_at.to_f})
    @reply = nil
    submit(key, "院区")
    assert_redirected_to admins_channel_qrcodes_path(app_id: @a.id)
    assert_equal "fresh", @calls.last.first
  end

  test "按公众号统计最近一次扫码关注；重复、已关注扫码与取关不累计，渠道名并入粉丝页" do
    submit(form, "门诊海报")
    code = OfficialAccountQrcode.sole
    other = OfficialAccountQrcode.create!(app: @b, name: "体检海报", scene: code.scene, url: code.url, ticket: "b")
    @stubs.get("/cgi-bin/user/info") { |env| response_for(openid: env.params["openid"], subscribe: 1, subscribe_scene: "ADD_SCENE_QR_CODE") }
    push = ->(type, seconds, scene, app = @a) do
      xml = "<xml><ToUserName>gh_#{app.appid}</ToUserName><FromUserName>fan-sample</FromUserName><MsgType>event</MsgType><Event>#{type}</Event><EventKey>#{scene}</EventKey><CreateTime>#{seconds}</CreateTime></xml>"
      signed_push(api_wechat_component_messages_path(appid: app.appid), xml)
      assert_response :success
    end
    at = 1.hour.ago.to_i
    Sidekiq.testing!(:inline) do
      2.times { push.call("subscribe", at, "qrscene_#{code.scene}") }
      push.call("SCAN", at + 1, "another-scene")
      push.call("unsubscribe", at + 2, "")
    end
    get admins_channel_qrcodes_path(app_id: @a.id, q: "门诊")
    assert_select "tbody tr", count: 1
    assert_select "td.d-none.d-sm-table-cell", text: "1"
    fan = OfficialAccountFan.for_app(@a).sole
    get admins_app_fan_path(@a, fan)
    assert_select "dd", text: code.name
    get admins_official_account_fans_path(app_id: @a.id)
    assert_select "td", text: code.name
    get admins_channel_qrcodes_path(app_id: @b.id)
    assert_select "td [data-list-text]", text: other.name
    assert_select "td.d-none.d-sm-table-cell", text: "0"
    get admins_channel_qrcodes_path(app_id: @b.id, q: code.name)
    assert_select ".empty-title", "未找到匹配的渠道二维码"
    assert_select "thead", count: 0
    submit(form, "住院服务台")
    new_code = OfficialAccountQrcode.order(:id).last
    Sidekiq.testing!(:inline) { push.call("subscribe", at + 5, "qrscene_#{new_code.scene}") }
    get admins_channel_qrcodes_path(app_id: @a.id, q: "门诊")
    assert_select "td.d-none.d-sm-table-cell", text: "0"
    get admins_channel_qrcodes_path(app_id: @a.id, q: "住院")
    assert_select "td.d-none.d-sm-table-cell", text: "1"
  end
end
