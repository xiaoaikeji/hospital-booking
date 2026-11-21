require "test_helper"

class AdminCustomersTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @reader = Admin.create!(username: "customer_reader", role: "customer_service")
    sign_in @reader
    @a = App.create!(provider: "wechat", appid: "fixture_clinic", nickname: "门诊小程序")
    @b = App.create!(provider: "wechat", appid: "fixture_branch", nickname: "分院小程序")
    @official = App.create!(provider: "wechat", app_type: "official_account", appid: "fixture_news", nickname: "医院公众号")
    @customer = User.create!(platform: "wechat", nickname: "小王", mobile: "10000000001", mobile_verified_at: 1.day.ago,
      last_login_at: Time.current, login_profile: { first_ip: "192.0.2.1", device_model: "测试手机", operating_system: "系统 1",
        region: { country: "中国", province: "广东省", city: "深圳市" } })
    @a_identity = UserApp.create!(user: @customer, app: @a, openid: "fixture-a-openid", unionid: "fixture-union",
      sign_in_count: 2, last_sign_in_at: 1.day.ago, first_entry: { launch_scene: 1047, channel_scene: "门诊大厅" })
    UserApp.create!(user: @customer, app: @b, openid: "fixture-b-openid", sign_in_count: 1, last_sign_in_at: Time.current,
      first_entry: { launch_scene: 1007, channel_scene: "分院入口" })
    @follower = User.create!(platform: "wechat", nickname: "仅关注用户", status: "disabled")
    followed = UserApp.create!(user: @follower, app: @official, openid: "fixture-follower")
    OfficialAccountFan.create!(user_app: followed, subscribed: true, observed_at: Time.current)
  end

  test "one row per account, distinct official account customers, and combined search and app filters" do
    other_app = App.create!(provider: "douyin", appid: @a.appid)
    other = User.create!(platform: "douyin", mobile: "10000000002")
    UserApp.create!(app: other_app, user: other, openid: "other-platform")

    get admins_customers_path
    assert_response :success
    assert_select "[data-customer-list] tbody tr", count: 3
    assert_select "tr", text: /小王.*10000000001.*已登录小程序/m, count: 1
    assert_select "tr", text: /仅关注用户.*仅公众号记录.*已停用.*尚未登录/m, count: 1
    refute_includes response.body, other.mobile

    [ @customer.user_no, "小王", @customer.verified_mobile ].each do |query|
      get admins_customers_path, params: { q: query, app_id: @a.id, status: "active" }
      assert_response :success
      assert_select "[data-customer-list] tbody tr", count: 1
      assert_select "td a", text: "小王"
    end
    get admins_customers_path, params: { app_id: @b.id }
    assert_select "[data-customer-list] tbody tr", count: 1
    assert_select "td a", text: "小王"
    get admins_customers_path, params: { app_id: @official.id, status: "disabled" }
    assert_select "[data-customer-list] tbody tr", count: 1
    assert_select "td a", text: @follower.nickname
    get admins_customers_path, params: { q: other.mobile }
    assert_select "[data-customer-list] table", count: 0
    assert_select ".empty-title", "没有找到匹配的客户"
  end

  test "details keep each app's first entry and reveal only the identity fields available to the current role" do
    filters = { app_id: @b.id, status: "active", q: "小王" }
    get admins_customer_path(@customer, filters)
    assert_response :success
    assert_includes response.headers.fetch("Cache-Control"), "no-store"
    assert_select "a[href=?]", admins_customers_path(filters), text: "返回列表"
    [ "10000000001", "中国 · 广东省 · 深圳市", "测试手机", "系统 1" ].each { |field| assert_select "dd", text: field }
    assert_select "div.list-group-item", text: /门诊小程序.*fixture_clinic.*1047.*门诊大厅/m, count: 1
    assert_select "div.list-group-item", text: /分院小程序.*fixture_branch.*1007.*分院入口/m, count: 1
    [ @a_identity.openid, @a_identity.unionid, "192.0.2.1", "sessions" ].each { |field| refute_includes response.body, field }

    sign_in Admin.create!(username: "customers_root", role: "super_admin")
    get admins_customer_path(@customer)
    assert_response :success
    assert_select "dd", text: @a_identity.openid
    assert_select "dd", text: @a_identity.unionid
    refute_includes response.body, "192.0.2.1"
  end

  test "pagination preserves filters and exposes each account on exactly one page" do
    users = 21.times.map { User.create!(platform: "wechat", nickname: "同批客户") }
    filters = { q: "同批客户", status: "active" }
    get admins_customers_path, params: filters
    assert_response :success
    assert_select "[data-customer-list] tbody tr", count: 20
    assert_select "nav[aria-label='列表分页'] a[href=?]", admins_customers_path(filters.merge(page: 2)), text: "下一页"
    assert_select "[data-customer-list] tbody", text: /#{users.first.user_no}/, count: 0
    get admins_customers_path, params: filters.merge(page: 2)
    assert_select "[data-customer-list] tbody tr", count: 1
    assert_select "[data-customer-list] tbody small", text: users.first.user_no
    assert_select "td a[href=?]", admins_customer_path(users.first, filters.merge(page: 2)), text: "查看"
  end

  test "customer queries require an enabled admin and no customer write route is available" do
    sign_out @reader
    [ admins_customers_path, admins_customer_path(@customer) ].each do |path|
      get path
      assert_redirected_to new_admin_session_path
    end
    @reader.update!(enabled: false)
    sign_in @reader
    get admins_customer_path(@customer)
    assert_redirected_to new_admin_session_path
    sign_in Admin.create!(username: "customer_operator", role: "operator")
    get admins_customer_path(@customer)
    assert_response :success
    assert_select "dd", text: @customer.verified_mobile
    refute_includes response.body, @a_identity.openid
    assert_no_changes -> { @customer.reload.status } do
      patch admins_customer_path(@customer), params: { user: { status: "disabled" } }
      assert_response :not_found
    end
  end
end
