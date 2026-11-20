require "test_helper"
require "sidekiq/testing"
require_relative "../support/wechat_http_test"

class OfficialAccountNotificationsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include WechatHttpTest

  setup do
    install_wechat_stubs
    @admin = Admin.create!(username: "reply_admin", role: "super_admin")
    sign_in @admin
    @a, @b = %w[wxReplyA wxReplyB].map do |appid|
      App.create!(provider: "wechat", app_type: "official_account", appid: appid, nickname: appid).tap do |account|
        auth = account.create_app_authorization!(refresh_token: "demo-token", original_id: "gh_#{appid}")
        Rails.cache.write("apps/#{account.id}/channel_token", { value: appid, revision: auth.updated_at.to_f })
      end
    end
    @mini = App.create!(provider: "wechat", appid: "wxActivityMini")
    @config = Notifications::AccountConfiguration.new(@a)
    @sent = []
    @stubs.post("/cgi-bin/message/custom/send") do |env|
      body = JSON.parse(env.body)
      @sent << [ env.params["access_token"], body ]
      raise Faraday::TimeoutError if @timeout
      response_for(errcode: body["msgtype"] == "miniprogrampage" && !@fixed ? 45015 : 0, errmsg: "reply time out of limit")
    end
    @stubs.get("/cgi-bin/user/info") { |env| response_for(openid: env.params["openid"], subscribe: 1, subscribe_time: Time.current.to_i) }
  end
  teardown { remove_wechat_stubs }

  def create_reply(name = "活动说明")
    proof = WechatPlatform::MenuButtons.proof(@a, "media_id", "cover-a")
    @config.save_reply!({ name: name, revision: @config.revision, messages: [
      { id: "text", type: "text", content: { text: "到了请去二楼签到" } },
      { id: "card", type: "miniprogrampage", proof: proof, content: { title: "活动入口", appid: @mini.appid, pagepath: "pages/activity/index", thumb_media_id: "cover-a" } }
    ] }, actor: @admin)[:id]
  end

  def code(name = "场馆门口")
    OfficialAccountQrcode.create!(app: @a, name: name, scene: "qd_#{SecureRandom.alphanumeric(12)}", ticket: "demo-ticket", url: "https://weixin.qq.com/q/demo")
  end

  def push(account = @a, **fields)
    message = { "ToUserName" => "gh_#{account.appid}", "FromUserName" => "fan-openid", "CreateTime" => Time.current.to_i.to_s, "MsgType" => "event", "Event" => "SCAN" }.merge(fields.stringify_keys)
    xml = "<xml>" + message.map { |k, v| "<#{k}>#{ERB::Util.html_escape(v)}</#{k}>" }.join + "</xml>"
    signed_push(api_wechat_component_messages_path(appid: account.appid), xml)
    assert_response :success
    message
  end

  test "建内容后菜单和码共用，仅改一码自动复制且原码继续用；菜单草稿发布前不影响线上" do
    id = create_reply
    qr = code
    menu = @a.create_official_account_menu!(buttons: [ { "name" => "怎么签到", "type" => "click", "key" => Notifications::AccountConfiguration.menu_key(id) } ])
    @config.bind_code!(qr, mode: "reply", reply_id: id, revision: @config.revision, actor: @admin)
    get edit_admins_app_reply_content_path(@a, id, qrcode_id: qr.id)
    assert_response :success
    assert_select "option[value=only][selected]", text: "仅改这个码"
    source = @config.reply(id)
    copy = @config.save_reply!({ id: id, name: "门口活动说明", revision: @config.revision, scope: "only", qrcode_id: qr.id, messages: source["messages"] + [ { id: "east", type: "text", content: { text: "请走东门" } } ] }, actor: @admin)
    assert_equal id, menu.reload.buttons.first["key"].delete_prefix("reply_")
    assert_equal copy[:id], @config.code_binding(qr.id)["reply_id"]
    assert_equal "到了请去二楼签到", @config.reply(id)["messages"].first.dig("content", "text")
    assert_equal qr.scene, qr.reload.scene
    assert_equal [ "线上菜单：怎么签到" ], @config.impacts(id)
    Sidekiq.testing!(:fake) do
      push(EventKey: qr.scene)
      assert_equal 1, Notification.count
      assert_equal 3, Notification.sole.messages.size
      2.times { Notifications::Delivery.run(Notification.sole.id) }
      assert_equal [ "wxReplyA", "wxReplyA" ], @sent.map(&:first)
      assert_equal %w[miniprogrampage text], @sent.map { |_, body| body["msgtype"] }
      push(Event: "CLICK", EventKey: "reply_#{id}")
      assert_equal "到了请去二楼签到", Notification.last.messages.first.dig("content", "text")
      assert_equal 2, Notification.last.messages.size
      assert_no_difference("Notification.count") { push(@b, Event: "CLICK", EventKey: "reply_#{id}") }
    end
  end

  test "文字成功卡片拒绝，补发只发卡片；重复回调不重复排队" do
    id = create_reply
    identity = UserApp.create!(app: @a, user: User.create!(platform: "wechat"), openid: "fan-openid")
    identity.create_official_account_fan!(subscribed: true, observed_at: 1.hour.ago, qr_scene: "original-source")
    qr = code
    @config.bind_code!(qr, mode: "reply", reply_id: id, revision: @config.revision, actor: @admin)
    row = Notifications.dispatch(event: "activity.reply", subject: @a, target: { channel_type: "wechat_official_account", channel_key: "official_account_#{@a.id}", app_id: @a.id, appid: @a.appid, user_app_id: identity.id }, messages: @config.reply(id)["messages"], idempotency_key: "two-messages")
    Notifications::Delivery.run(row.id)
    assert_equal %w[sent failed], row.reload.messages.map { |m| row.result_for(m["id"])["status"] }
    @fixed = true
    post retry_failed_admins_notification_path(row), params: { message_ids: [ "card" ] }
    Notifications::Delivery.run(row.id)
    assert_equal %w[text miniprogrampage miniprogrampage], @sent.map { |_, body| body["msgtype"] }
    assert_equal "sent", row.reload.status
    @sent.clear
    Sidekiq.testing!(:fake) do
      2.times { push(EventKey: qr.scene) }
      callback_task = Notification.last
      envelope = Nokogiri::XML(response.body)
      plain = Wechat::MessageCrypto.new(@component).decrypt(envelope.at_xpath("//Encrypt").text,
        timestamp: envelope.at_xpath("//TimeStamp").text, nonce: envelope.at_xpath("//Nonce").text, signature: envelope.at_xpath("//MsgSignature").text)
      assert_includes plain.force_encoding("UTF-8"), "到了请去二楼签到"
      assert_equal 1, OfficialAccountCallback.count
      Notifications::Delivery.run(callback_task.id)
      assert_equal [ "miniprogrampage" ], @sent.map { |_, body| body["msgtype"] }
      assert_equal "passive_response", callback_task.reload.result_for("text")["stage"]
      assert_equal "original-source", identity.official_account_fan.reload.qr_scene
    end
  end

  test "公众号变量使用本账号身份及渠道，文字应答和后续发送在登记时固定" do
    a_user = User.create!(platform: "wechat", nickname: "甲粉丝")
    a_identity = UserApp.create!(app: @a, user: a_user, openid: "fan-openid")
    a_identity.create_official_account_fan!(subscribed: true, observed_at: 1.hour.ago, qr_scene: "original-source")
    b_user = User.create!(platform: "wechat", nickname: "乙粉丝")
    b_identity = UserApp.create!(app: @b, user: b_user, openid: "fan-openid")
    b_identity.create_official_account_fan!(subscribed: true, observed_at: 1.hour.ago)
    messages = [ { id: "first", type: "text", content: { text: "您好{name}，欢迎来到{app_name}" } },
      { id: "rest", type: "text", content: { text: "编号：{user_id}\n渠道：{qrcode_name}" } } ]
    a_id = @config.save_reply!({ revision: @config.revision, name: "变量回复", messages: messages }, actor: @admin)[:id]
    qr = code("A 入口")
    @config.bind_code!(qr, mode: "reply", reply_id: a_id, revision: @config.revision, actor: @admin)
    b_config = Notifications::AccountConfiguration.new(@b)
    b_id = b_config.save_reply!({ revision: b_config.revision, name: "B 变量回复", messages: messages }, actor: @admin)[:id]
    b_qr = OfficialAccountQrcode.create!(app: @b, name: "B 入口", scene: qr.scene, ticket: "b-ticket", url: qr.url)
    b_config.bind_code!(b_qr, mode: "reply", reply_id: b_id, revision: b_config.revision, actor: @admin)
    seconds = Time.current.to_i.to_s
    Sidekiq.testing!(:fake) do
      push(CreateTime: seconds, EventKey: qr.scene)
      a_task = Notification.sole
      assert_equal "您好甲粉丝，欢迎来到wxReplyA", a_task.messages.first.dig("content", "text")
      assert_includes a_task.messages.last.dig("content", "text"), a_user.user_no
      assert_includes a_task.messages.last.dig("content", "text"), "A 入口"
      a_user.update!(nickname: "后来改名")
      2.times { push(CreateTime: seconds, EventKey: qr.scene) }
      Notifications::Delivery.run(a_task.id)
      assert_equal 1, @sent.size
      assert_equal "wxReplyA", @sent.last.first
      assert_includes @sent.last.last.dig("text", "content"), "A 入口"
      push(@b, EventKey: b_qr.scene)
      b_task = Notification.last
      assert_equal "您好乙粉丝，欢迎来到wxReplyB", b_task.messages.first.dig("content", "text")
      assert_includes b_task.messages.last.dig("content", "text"), "B 入口"
      assert_not_includes b_task.messages.last.dig("content", "text"), a_user.user_no
      assert_equal "original-source", a_identity.official_account_fan.reload.qr_scene
    end
    get edit_admins_app_reply_content_path(@a, a_id)
    assert_select "[data-insert-variable=name]"
    assert_select "[data-insert-variable=qrcode_name]"
    assert_select "[data-insert-variable=balance]", count: 0
  end

  test "旧的静态回复不自动解释大括号，显式保存后才启用变量" do
    id = SecureRandom.uuid
    @config.update!(@config.revision, actor: @admin, request: nil, action: "notification.reply_save") do |data|
      data["replies"] = { id => { "name" => "旧回复", "messages" => [ { "id" => "legacy", "type" => "text", "content" => { "text" => "原样 {literal}" } } ] } }
    end
    qr = code
    @config.bind_code!(qr, mode: "reply", reply_id: id, revision: @config.revision, actor: @admin)
    Sidekiq.testing!(:fake) do
      push(EventKey: qr.scene)
      assert_equal "原样 {literal}", Notification.sole.messages.first.dig("content", "text")
    end
    @config.save_reply!({ id: id, revision: @config.revision, impact_revision: @config.impact_revision(id), scope: "all", name: "旧回复", messages: [ { id: "legacy", type: "text", content: { text: "原样 {{literal}}" } } ] }, actor: @admin)
    Sidekiq.testing!(:fake) do
      push(EventKey: qr.scene, CreateTime: (Time.current.to_i + 1).to_s)
      assert_equal "原样 {literal}", Notification.last.messages.first.dig("content", "text")
    end
  end

  test "首次与再次关注使用不同绑定，重复关注回调不重复发送" do
    first = create_reply
    again = @config.save_reply!({ name: "再次欢迎", revision: @config.revision, messages: [ { id: "again", type: "text", content: { text: "欢迎再次参加" } } ] }, actor: @admin)[:id]
    @config.save_rules!({ revision: @config.revision, follow_first: first, follow_again: again }, actor: @admin)
    Sidekiq.testing!(:fake) do
      # 未匹配文字不能把第一次关注误当成再次关注。
      push(MsgType: "text", Content: "未匹配文字", MsgId: "no-match")
      push(Event: "subscribe")
      assert_equal "到了请去二楼签到", Notification.sole.messages.first.dig("content", "text")
      WechatPlatform::FanEventWorker.new.perform(OfficialAccountFanEvent.sole.id)
      push(Event: "unsubscribe", CreateTime: (Time.current.to_i + 1).to_s)
      WechatPlatform::FanEventWorker.new.perform(OfficialAccountFanEvent.sole.id)
      2.times { push(Event: "subscribe", CreateTime: (Time.current.to_i + 2).to_s) }
      assert_equal 2, Notification.count
      assert_equal "欢迎再次参加", Notification.last.messages.first.dig("content", "text")
    end
  end

  test "首次再次关注、欢迎加专属、关键词和待核实均按账号处理" do
    id = create_reply
    @config.save_rules!({ revision: @config.revision, follow_first: id, follow_again: id, keywords: [ { words: "签到，Help", match: "exact", reply_id: id } ] }, actor: @admin)
    qr = code
    @config.bind_code!(qr, mode: "both", reply_id: id, revision: @config.revision, actor: @admin)
    Sidekiq.testing!(:fake) do
      push(Event: "subscribe", EventKey: "qrscene_#{qr.scene}")
      assert_equal 1, Notification.count
      assert_equal 4, Notification.sole.messages.size
      WechatPlatform::FanEventWorker.new.perform(OfficialAccountFanEvent.sole.id)
      assert_equal qr.scene, OfficialAccountFan.sole.qr_scene
      push(MsgType: "text", Content: "help", MsgId: "11")
      assert_equal 2, Notification.count
      @timeout = true
      task = Notification.last
      Notifications::Delivery.run(task.id)
      assert_equal "待核实", task.reload.status_label
      assert_equal "awaiting_verification", task.result_for("card")["stage"]
      get admins_notification_path(task)
      assert_response :success
      assert_includes response.body, "待核实"
    end
    assert_empty Notifications::AccountConfiguration.new(@b).replies
    cross = Notifications::AccountConfiguration.new(@b)
    assert_raises(Notifications::Error) { cross.save_rules!({ revision: cross.revision, follow_first: id }, actor: @admin) }
    assert_raises(Notifications::Error) { cross.save_reply!({ revision: cross.revision, name: "串号卡片", messages: @config.reply(id)["messages"] }, actor: @admin) }
  end
end
