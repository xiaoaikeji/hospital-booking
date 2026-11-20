require "test_helper"
require_relative "../support/wechat_http_test"
require "sidekiq/testing"

class OfficialAccountFansTest < ActionDispatch::IntegrationTest
  include WechatHttpTest
  include Devise::Test::IntegrationHelpers

  setup do
    install_wechat_stubs
    @admin = Admin.create!(username: "fans_admin", role: "super_admin")
    sign_in @admin
    @a, @b = %w[wx1111111111111111 wx2222222222222222].map do |id|
      app = App.create!(provider: "wechat", appid: id, app_type: "official_account", nickname: "服务号 #{id.last}")
      auth = app.create_app_authorization!(refresh_token: "demo", original_id: "gh_#{id}")
      Rails.cache.write("apps/#{app.id}/channel_token", {value: id, revision: auth.updated_at.to_f})
      app
    end
    @mini = App.create!(provider: "wechat", appid: "wx3333333333333333")
    @ids = %w[first second]
    @profiles = {}
    @requests = []
    @stubs.get("/cgi-bin/user/get") do |env|
      @requests << [env.params["access_token"], env.params["next_openid"]]
      response_for(@list ? @list.call(env.params["next_openid"]) : { total: @ids.size, count: @ids.size, data: { openid: @ids }, next_openid: "" })
    end
    @stubs.post("/cgi-bin/user/info/batchget") do |env|
      ids = JSON.parse(env.body).fetch("user_list").pluck("openid")
      @sizes ||= []
      @sizes << ids.size
      rows = ids.map { |id| profile(id) }
      response_for(user_info_list: @partial ? rows.drop(1) : rows)
    end
    @stubs.get("/cgi-bin/user/info") { |env| response_for(@profile_error || profile(env.params["openid"])) }
  end
  teardown { remove_wechat_stubs }

  def profile(id)
    {"openid" => id, "subscribe" => 1, "subscribe_time" => 1.day.ago.to_i, "subscribe_scene" => "ADD_SCENE_SEARCH"}.merge(@profiles.fetch(id, {}))
  end

  def sync(app = @a)
    run = OfficialAccountFanSync.create!(app: app, operator: @admin)
    WechatPlatform::FanSyncWorker.new.perform(run.id)
    run.reload
  end

  def fan(app, id)
    OfficialAccountFan.for_app(app).find_by!(user_apps: { openid: id })
  end

  test "按公众号同步、确认、防止重排、筛选详情与访问权限" do
    get admins_app_path(@a)
    assert_select "a[href=?]", admins_official_account_fans_path(app_id: @a.id), text: "粉丝列表"
    get admins_official_account_fans_path(app_id: @a.id)
    assert_select ".empty-title", "还没有粉丝"
    assert_select "#fan-sync", text: /#{@a.appid}/
    Sidekiq.testing!(:fake) do
      assert_difference("WechatPlatform::FanSyncWorker.jobs.size", 1) do
        2.times { post sync_admins_app_fans_path(@a, q: "张", status: "subscribed", page: 2) }
      end
      assert_redirected_to admins_official_account_fans_path(app_id: @a.id, q: "张", status: "subscribed", page: 2)
      WechatPlatform::FanSyncWorker.drain
    end
    assert_equal [[@a.appid, nil]], @requests
    row = fan(@a, "first")
    user = row.user_app.user
    user.update!(nickname: "张女士")
    assert_match(/\A[1-9]\d{7}\z/, user.user_no)
    assert_nil user.last_login_at
    assert_equal 0, row.user_app.sign_in_count
    get admins_official_account_fans_path(app_id: @a.id, q: "张", status: "subscribed")
    assert_select "table tbody tr", count: 1
    assert_select "a", text: "张女士"
    get admins_app_fan_path(@a, row, q: user.user_no)
    assert_select "dd", text: "张女士"
    assert_select "a[href=?]", admins_official_account_fans_path(app_id: @a.id, q: user.user_no), text: /返回列表/
    get admins_app_fan_path(@b, row)
    assert_response :not_found
    @b.app_authorization.update!(refresh_token: nil)
    get admins_official_account_fans_path(app_id: @b.id)
    assert_select "#fan-sync", count: 0
    post sync_admins_app_fans_path(@b)
    assert_match(/授权/, flash[:alert])
    assert_empty OfficialAccountFanSync.where(app: @b)
    post sync_admins_app_fans_path(@mini)
    assert_response :not_found
    %w[operator customer_service].each do |role|
      sign_in Admin.create!(username: "fan_#{role}", role: role)
      get admins_official_account_fans_path
      assert_response :forbidden
      get admins_app_fan_path(@a, row)
      assert_response :forbidden
      post sync_admins_app_fans_path(@a)
      assert_response :forbidden
    end
    assert Log.operations_visible_to(@admin).exists?(action: "wechat.fan_sync", target_type: "App", target_id: @a.id)
    assert_not_includes Log.where(action: "wechat.fan_sync").pluck(:details).to_json, "first"
  end

  test "分页每百人取资料、完整名单才核销、其他账号与同步期间的回调不受影响" do
    @ids = ["gone"]
    sync
    sync(@b)
    batch = (1..101).map { |n| "page-#{n}" }
    @list = ->(cursor) do
      if cursor.nil?
        { total: 102, count: 101, data: {openid: batch}, next_openid: "next" }
      else
        WechatPlatform::OfficialAccountFans.new(@a).event!("late", "subscribe", 2.seconds.ago.to_i, nil)
        { total: 102, count: 1, data: {openid: ["last"]}, next_openid: "" }
      end
    end
    run = sync
    assert_equal "success", run.state
    assert_equal [100, 1, 1], @sizes.last(3)
    assert_equal [nil, "next"], @requests.last(2).map(&:last)
    assert_not fan(@a, "gone").subscribed?
    assert_nil fan(@a, "gone").unsubscribed_at
    assert fan(@a, "late").subscribed?
    assert fan(@b, "gone").subscribed?
    assert_equal 103, run.fan_count
  end

  test "名单截断、游标循环、资料缺行均不能标记名单外的关注者取关，旧失败任务不覆盖新的成功" do
    sync
    @list = ->(_) { { total: 3, count: 0, next_openid: "" } }
    old = sync
    assert_equal "failed", old.state
    assert fan(@a, "second").subscribed?
    @list = ->(_) { {total: 4, count: 1, data: {openid: ["first"]}, next_openid: "again"} }
    assert_equal "failed", sync.state
    @list = nil
    @partial = true
    assert_raises(HttpConnection::Unavailable) { sync }
    assert fan(@a, "second").subscribed?
    @partial = false
    @ids.clear
    assert_equal "success", sync.state
    assert_not fan(@a, "second").subscribed?
    count = @requests.size
    WechatPlatform::FanSyncWorker.new.perform(old.id)
    assert_equal count, @requests.size
  end

  test "同开放平台可信 UnionID 才复用账号，绑定切换不使用旧 UnionID" do
    group = OpenPlatformAccount.create!(open_appid: "open-one", name: "本院", created_via_app: @a, operator: @admin)
    [@mini, @a].each { |app| app.update!(open_platform_account: group) }
    user = User.create!(platform: "wechat", nickname: "已有用户")
    identity = UserApp.create!(user: user, app: @mini, openid: "mini-1", unionid: "trusted", sign_in_count: 1)
    @profiles["first"] = {"unionid" => "trusted"}
    sync
    assert_equal user.id, fan(@a, "first").user_app.user_id
    sync(@b)
    assert_not_equal user.id, fan(@b, "first").user_app.user_id
    get admins_app_fan_path(@a, fan(@a, "first"))
    assert_select "dd", text: "是"
    @mini.update!(open_platform_account: nil)
    assert_nil identity.reload.unionid
    assert_no_difference "User.count" do
      sync
      sync(@b)
    end
  end

  test "验签回调检查应用归属、重复与晚到顺序，保留扫码来源和实际取关时间" do
    id = "subscriber-demo"
    time = 2.hours.ago.to_i
    push_event = ->(event, at, path_app = @a, tamper = false) do
      xml = "<xml><ToUserName>gh_#{@a.appid}</ToUserName><FromUserName>#{id}</FromUserName><MsgType>event</MsgType><Event>#{event}</Event><EventKey>qrscene_hospital</EventKey><CreateTime>#{at}</CreateTime></xml>"
      signed_push(api_wechat_component_messages_path(appid: path_app.appid), xml, tamper: tamper)
    end
    Sidekiq.testing!(:fake) do
      2.times { push_event.call("subscribe", time) }
      queued = OfficialAccountFanEvent.sole
      assert_equal [queued.id], WechatPlatform::FanEventWorker.jobs.last.fetch("args")
      assert_not_equal id, queued.openid_before_type_cast
      WechatPlatform::FanEventWorker.drain
      assert_empty OfficialAccountFanEvent.all
    end
    Sidekiq.testing!(:inline) do
      push_event.call("subscribe", time, @b)
      assert_response :forbidden
      push_event.call("subscribe", time, @a, true)
      assert_response :forbidden
      assert_empty OfficialAccountFan.for_app(@b)
      2.times { push_event.call("subscribe", time) }
      assert_response :success
      assert_equal "hospital", fan(@a, id).channel
      push_event.call("unsubscribe", time + 50)
      push_event.call("subscribe", time + 25)
      assert_not fan(@a, id).subscribed?
      assert_equal time + 50, fan(@a, id).unsubscribed_at.to_i
      @profile_error = { errcode: 48001 }
      push_event.call("subscribe", time + 60)
      assert fan(@a, id).subscribed?
      assert_nil fan(@a, id).unsubscribed_at
      assert_equal 1, OfficialAccountFan.count
    end
  end

  test "微信拒绝同步在原页保留历史与原因，解除授权后排队任务不读取微信" do
    sync
    @list = ->(_) { {errcode: 48001} }
    rejected = sync
    assert_equal "failed", rejected.state
    get admins_official_account_fans_path(app_id: @a.id)
    assert_select ".alert-warning", /48001/
    assert_select "tbody tr", count: 2
    assert_select "button", text: /同步已有粉丝/
    queued = OfficialAccountFanSync.create!(app: @a, operator: @admin)
    @a.app_authorization.update!(refresh_token: nil)
    before = @requests.size
    WechatPlatform::FanSyncWorker.new.perform(queued.id)
    assert_equal before, @requests.size
    assert_equal "failed", queued.reload.state
    get admins_official_account_fans_path(app_id: @a.id)
    assert_select "tbody tr", count: 2
    assert_select "#fan-sync", count: 0
  end
end
