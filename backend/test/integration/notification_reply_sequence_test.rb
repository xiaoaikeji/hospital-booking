require "test_helper"
require "sidekiq/testing"
require_relative "../support/wechat_http_test"

class NotificationReplySequenceTest < ActionDispatch::IntegrationTest
  include WechatHttpTest
  include Devise::Test::IntegrationHelpers

  setup do
    install_wechat_stubs
    @admin = Admin.create!(username: "reply_sequence_admin", role: "super_admin")
    sign_in @admin
    @a, @b = %w[wxPointA wxPointB].map do |appid|
      account = App.create!(provider: "wechat", app_type: "official_account", appid: appid)
      auth = account.create_app_authorization!(refresh_token: "local", original_id: "gh_#{appid}")
      Rails.cache.write("apps/#{account.id}/channel_token", { value: appid, revision: auth.updated_at.to_f })
      account
    end
    @mini = App.create!(provider: "wechat", appid: "wxDemoMini")
    @config = Notifications::AccountConfiguration.new(@a)
    @sent = []
    @stubs.post("/cgi-bin/message/custom/send") do |env|
      @sent << [ env.params.fetch("access_token"), JSON.parse(env.body) ]
      response_for(errcode: 0)
    end
  end
  teardown { remove_wechat_stubs }

  def create_reply(name, messages, account: @a)
    post admins_app_reply_contents_path(account), params: { reply_content: {
      name: name, revision: Notifications::AccountConfiguration.new(account).revision, messages: messages
    } }, as: :json
    assert_response :success
    response.parsed_body.fetch("id")
  end

  def push(account, event, scene)
    fields = { ToUserName: "gh_#{account.appid}", FromUserName: "shared-test-openid", CreateTime: Time.current.to_i,
      MsgType: "event", Event: event, EventKey: scene }
    signed_push(api_wechat_component_messages_path(appid: account.appid), fields.to_xml(root: "xml", skip_types: true))
    assert_response :success
  end

  test "带入当前公众号旧菜单原文，只在发布后切换回复" do
    Sidekiq.testing!(:fake) do
      nodes = [ { "type" => "text", "name" => "地址", "value" => "门诊一楼", "legacy" => true } ]
      existing = OfficialAccountMenu.create!(app: @a, buttons: nodes)
      params = { inline: "1", menu_index: "0", menu_revision: existing.revision.to_s }
      get new_admins_app_reply_content_path(@a), params: params
      assert_response :success
      draft = JSON.parse(css_select("[data-reply-editor]").first["data-reply"])
      assert_equal "地址", draft.fetch("name")
      assert_equal "门诊一楼", draft.fetch("messages").sole.dig("content", "text")
      id = create_reply(draft.fetch("name"), draft.fetch("messages"))
      assert_equal nodes, existing.reload.buttons
      get new_admins_app_reply_content_path(@b), params: params
      assert_response :not_found
      wire = []
      @stubs.post("/cgi-bin/menu/create") { |env| wire << JSON.parse(env.body); response_for(errcode: 0) }
      key = Notifications::AccountConfiguration.menu_key(id)
      post publish_admins_app_official_account_menu_path(@a), params: {
        revision: existing.revision.to_s, buttons: [ { name: "地址", type: "click", key: key } ]
      }, as: :json
      assert_response :success
      assert_equal key, wire.sole.fetch("button").sole.fetch("key")
      push(@a, "CLICK", key)
      assert_equal "门诊一楼", Notification.sole.messages.sole.dig("content", "text")
    end
  end

  test "欢迎卡片在前时，专属文字不能抢先被动回复，重放和同名扫码来源按账号隔离" do
    Sidekiq.testing!(:fake) do
      content = { title: "签到卡", appid: @mini.appid, pagepath: "pages/check_in/index", thumb_media_id: "cover_A" }
      card = { id: "first", type: "miniprogrampage", content: content,
        proof: WechatPlatform::MenuButtons.proof(@a, "card_cover", "cover_A") }
      welcome = create_reply("欢迎", [ card ])
      text = { id: "first", type: "text", content: { text: "请走东门" } }
      entrance = create_reply("东门说明", [ text ])
      @config.save_rules!({ revision: @config.revision, follow_first: welcome, follow_again: welcome }, actor: @admin)
      code = OfficialAccountQrcode.create!(app: @a, name: "东门", scene: "qd_123456789ABC", ticket: "local", url: "https://example.test/gate")
      @config.bind_code!(code, mode: "both", reply_id: entrance, revision: @config.revision, actor: @admin)
      freeze_time do
        2.times { push(@a, "subscribe", "qrscene_#{code.scene}") }
        assert_equal "success", response.body
        push(@b, "subscribe", "qrscene_#{code.scene}")
        assert_equal "success", response.body
      end
      task = Notification.sole
      assert_equal 2, task.messages.map { |m| m["id"] }.uniq.length
      Notifications::DeliveryWorker.new.perform(task.id)
      assert_equal %w[miniprogrampage text], @sent.map { |_, body| body.fetch("msgtype") }
      assert_equal [ @a.appid, @a.appid ], @sent.map(&:first)
      assert_equal [ "shared-test-openid" ] * 2, @sent.map { |_, b| b.fetch("touser") }
      assert_equal "请走东门", @sent.last.last.dig("text", "content")
      assert_equal "sent", task.reload.status
    end
  end

  test "场馆门口码选仅改这个码时隐藏影响范围、复制后仍是原码，选更新全部才展示影响范围" do
    Sidekiq.testing!(:fake) do
      card = { id: "card", type: "miniprogrampage", content: { title: "查看活动", appid: @mini.appid,
        pagepath: "pages/activities/show", thumb_media_id: "image-A" }, proof: WechatPlatform::MenuButtons.proof(@a, "card_cover", "image-A") }
      contents = [ { id: "sign", type: "text", content: { text: "到了请去二楼签到" } }, card ]
      reply_id = create_reply("活动说明", contents)
      key = Notifications::AccountConfiguration.menu_key(reply_id)
      @stubs.post("/cgi-bin/menu/create") { response_for(errcode: 0) }
      post publish_admins_app_official_account_menu_path(@a), params: { revision: "0",
        buttons: [ { name: "怎么签到", type: "click", key: key } ] }, as: :json
      assert_response :success
      qr_requests = []
      @stubs.post("/cgi-bin/qrcode/create") do |env|
        scene = JSON.parse(env.body).dig("action_info", "scene", "scene_str")
        qr_requests << scene
        response_for(ticket: "venue-ticket", url: "http://weixin.qq.com/q/#{scene}")
      end
      get new_admins_app_channel_qrcode_path(@a)
      assert_response :success
      form_key = css_select("input[name=form_key]").first["value"]
      post admins_app_channel_qrcodes_path(@a), params: { form_key: form_key, official_account_qrcode: { name: "场馆门口" },
        reply_binding: { mode: "reply", reply_id: reply_id, revision: @config.revision } }
      assert_redirected_to admins_channel_qrcodes_path(app_id: @a.id)
      code = OfficialAccountQrcode.where(app: @a).sole
      assert_includes @config.impacts(reply_id), "线上菜单：怎么签到"
      assert_includes @config.impacts(reply_id), "渠道码：场馆门口"

      get edit_admins_app_reply_content_path(@a, reply_id, qrcode_id: code.id)
      assert_response :success
      assert_select "#reply-scope option[value=only][selected]", text: "仅改这个码"
      assert_select "[data-reply-impacts].d-none", count: 1

      get edit_admins_app_reply_content_path(@a, reply_id)
      assert_response :success
      assert_select "#reply-scope option[value=all][selected]", text: "更新全部"
      assert_select "[data-reply-impacts]:not(.d-none)", count: 1

      patch admins_app_reply_content_path(@a, reply_id), params: { reply_content: { name: "活动说明（东门）", scope: "only",
        revision: @config.revision, qrcode_id: code.id, messages: contents + [ { id: "east", type: "text", content: { text: "请走东门" } } ] } }, as: :json
      assert_response :success
      copy_id = response.parsed_body.fetch("id")
      assert_not_equal reply_id, copy_id
      assert_equal copy_id, @config.code_binding(code.id).fetch("reply_id")
      assert_equal [ code.scene ], qr_requests
      assert_equal key, @a.reload.official_account_menu.buttons.sole.fetch("key")

      freeze_time do
        2.times { push(@a, "SCAN", code.scene) }
        encrypted = Nokogiri::XML(response.body)
        plain = Wechat::MessageCrypto.new(@component).decrypt(encrypted.at_xpath("//Encrypt").text,
          timestamp: encrypted.at_xpath("//TimeStamp").text, nonce: encrypted.at_xpath("//Nonce").text,
          signature: encrypted.at_xpath("//MsgSignature").text)
        assert_equal "到了请去二楼签到", Nokogiri::XML(plain).at_xpath("//Content").text
        push(@b, "SCAN", code.scene)
        assert_equal "success", response.body
        push(@a, "CLICK", key)
      end
      scan = Notification.find_by!(event: "official_account.scan")
      menu = Notification.find_by!(event: "official_account.click")
      assert_equal [ 3, 2 ], [ scan.messages.size, menu.messages.size ]
      [ scan, menu ].each { |task| Notifications::DeliveryWorker.new.perform(task.id) }
      assert_equal %w[miniprogrampage text miniprogrampage], @sent.map { |_, m| m["msgtype"] }
      assert_equal "请走东门", @sent[1][1].dig("text", "content")
      assert_equal [ "passive_response", "channel_accepted", "channel_accepted" ],
        scan.reload.messages.map { |m| scan.result_for(m["id"]).fetch("stage") }
      get admins_notification_path(scan)
      assert_response :success
      assert_includes response.body, "请走东门"
      assert_includes response.body, "渠道已接受"
    end
  end
end
