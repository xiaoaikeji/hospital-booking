require "test_helper"
require "sidekiq/testing"
require_relative "../support/wechat_http_test"

class MapProvidersTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include WechatHttpTest

  setup do
    install_wechat_stubs
    @admin = Admin.create!(username: "settings_map", role: "super_admin")
    sign_in @admin
  end
  teardown { remove_wechat_stubs }

  test "an existing Baidu key works before any edit and the form preserves each provider's credential and source" do
    previous_env = ENV["TENCENT_MAP_KEY"]
    ENV["TENCENT_MAP_KEY"] = external = SecureRandom.hex
    old = legacy_ak
    get edit_admins_system_settings_map_path
    assert_response :success
    assert_select "select[name='map[provider]'] option[value=baidu][selected]"
    assert_select "fieldset[data-map-credential=baidu]:not([hidden]) input[type=text][data-write-only][autocomplete=off]:not([value])"
    assert_select "fieldset[data-map-credential=tencent][disabled] input[type=text][data-write-only][autocomplete=off]:not([value])"
    assert_select "[data-map-credential] [data-credential-status]", text: "已配置", count: 2
    [ old, external ].each { |key| assert_not_includes response.body, key }
    assert_equal "加密数据库", MapSettings.new.source("ak")
    assert_equal "环境变量", MapSettings.new.source("tencent_key")

    patch_settings(provider: "tencent", tencent_key: external)
    assert_redirected_to edit_admins_system_settings_map_path
    assert_equal external, MapSettings.new.key
    assert_nil Setting.find_by(key: "tencent_map")
    settings = MapSettings.new
    assert_not settings.save({ provider: "tencent", tencent_key: 12345, revision: settings.revision }, actor: @admin, request: nil)
    assert_equal external, MapSettings.new.key
    current = MapSettings.new.revision
    ENV["TENCENT_MAP_KEY"] = rotated = SecureRandom.hex
    patch admins_system_settings_map_path, params: { map: { revision: current, tencent_key: external } }
    assert_response :unprocessable_content
    [ old, external, rotated ].each { |key| assert_not_includes response.body, key }
    replacement = SecureRandom.hex
    patch_settings(provider: "tencent", tencent_key: replacement, ak: SecureRandom.hex)
    assert_redirected_to edit_admins_system_settings_map_path
    get edit_admins_system_settings_map_path
    assert_select "fieldset[data-map-credential=tencent]:not([hidden]) input[type=text][data-write-only][autocomplete=off]:not([value])"
    assert_not_includes response.body, replacement
    assert_equal "加密数据库", MapSettings.new.source("tencent_key")
    assert_predicate Setting.find_by!(key: "tencent_map").settings.fetch("key").fetch("ciphertext"), :present?
    refute_includes Setting.find_by!(key: "tencent_map").settings.to_json, replacement
    patch_settings(provider: "baidu")
    assert_equal old, MapSettings.new.key
    patch_settings(provider: "tencent")
    assert_equal replacement, MapSettings.new.key
    patch_settings(clear_settings: "1")
    assert_redirected_to edit_admins_system_settings_map_path
    assert_equal "baidu", MapSettings.new.provider
    assert_equal "环境变量", MapSettings.new.source("tencent_key")
    assert_not MapSettings.new.stored?
    Log.where(action: "map_settings.update").each do |event|
      assert_equal [ "fields" ], event.details.keys
      assert_empty event.details.fetch("fields") - %w[provider ak tencent_key]
    end
  ensure
    ENV["TENCENT_MAP_KEY"] = previous_env
  end

  test "switching to Tencent during a Baidu request ignores its late result and old cooldown, and only fills a pending region" do
    ak = legacy_ak
    key = SecureRandom.hex
    pending = User.create!(platform: "wechat", login_profile: { first_ip: "8.8.8.8" })
    retained = { "country" => "CN", "city" => "厦门市" }
    located = User.create!(platform: "wechat", login_profile: { first_ip: "1.1.1.1", region: retained })
    @stubs.get("/location/ip") do |env|
      assert_equal "api.map.baidu.com", env.url.host
      assert_equal({ "ip" => "8.8.8.8", "ak" => ak }, env.params)
      patch_settings(provider: "tencent", tencent_key: key)
      assert_redirected_to edit_admins_system_settings_map_path
      response_for(status: 0, address: "CN|广东省|广州市")
    end
    @stubs.get("/ws/location/v1/ip") do |env|
      assert_equal "apis.map.qq.com", env.url.host
      assert_equal({ "ip" => "8.8.8.8", "key" => key }, env.params)
      response_for(status: "0", result: { ad_info: { nation: "中国", province: "广东省", city: "深圳市", district: "南山区" } })
    end
    worker = UserIpLocationWorker.new
    Sidekiq.testing!(:fake) do
      assert_difference -> { UserIpLocationWorker.jobs.size }, 1 do
        2.times { worker.perform }
      end
      UserIpLocationWorker.drain
      assert_equal "tencent", MapSettings.new.provider
      refute pending.reload.login_profile.key?("region")
      assert_difference -> { UserIpLocationWorker.jobs.size }, 1 do
        2.times { worker.perform }
      end
      assert_equal [ pending.id ], UserIpLocationWorker.jobs.last.fetch("args")
      UserIpLocationWorker.drain
      assert_equal({ "country" => "中国", "province" => "广东省", "city" => "深圳市" }, pending.reload.login_profile["region"])
      assert_equal retained, located.reload.login_profile["region"]
      patch_settings(provider: "baidu")
      assert_no_difference -> { UserIpLocationWorker.jobs.size } do
        worker.perform
      end
    ensure
      UserIpLocationWorker.clear
    end
  end

  test "login, verified phone and profile remain available without a Tencent key, during timeout and after quota rejection" do
    mini_app = App.create!(provider: "wechat", appid: "fixture_map", appsecret: SecureRandom.hex, status: "active")
    patch_settings(provider: "tencent")
    assert_nil MapSettings.new.key
    @stubs.get("/sns/jscode2session") { response_for(openid: "map-fixture") }
    @stubs.post("/cgi-bin/stable_token") { response_for(access_token: SecureRandom.hex, expires_in: 7200) }
    @stubs.post("/wxa/business/getuserphonenumber") do
      response_for(phone_info: { purePhoneNumber: "10000000001", countryCode: 86, watermark: { appid: mini_app.appid } })
    end
    @stubs.get("/ws/location/v1/ip") do
      raise Faraday::TimeoutError if @timeout
      response_for(status: 121)
    end
    %i[missing timeout quota].each do |failure|
      patch_settings(tencent_key: SecureRandom.hex) if failure == :timeout
      @timeout = failure == :timeout
      post api_mini_program_session_path(mini_app.appid), params: { code: SecureRandom.hex }, headers: { "REMOTE_ADDR" => "8.8.8.8" }, as: :json
      assert_response :created
      auth = { "Authorization" => "Bearer #{response.parsed_body.fetch("token")}" }
      id = UserApp.for_app(mini_app).sole.user_id
      if failure == :missing
        assert_nil UserIpLocationWorker.new.perform(id)
      else
        assert_raises(HttpConnection::Unavailable) { UserIpLocationWorker.new.perform(id) }
      end
      post api_mini_program_phone_binding_path(mini_app.appid), params: { code: SecureRandom.hex }, headers: auth, as: :json
      assert_response :success
      get api_mini_program_me_path(mini_app.appid), headers: auth
      assert_response :success
      assert_equal "10000000001", response.parsed_body.fetch("mobile")
      assert_nil response.parsed_body["region"]
    end
  end

  private

  def legacy_ak
    ak = SecureRandom.hex
    row = Setting.new(key: "baidu_map")
    row.write_value("ak", ak)
    row.save!
    ak
  end

  def patch_settings(**values)
    patch admins_system_settings_map_path, params: { map: values.merge(revision: MapSettings.new.revision) }
  end
end
