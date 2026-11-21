require "test_helper"
require_relative "../support/wechat_http_test"

class MiniProgramLoginTest < ActionDispatch::IntegrationTest
  include WechatHttpTest

  class RequestCache < ActiveSupport::Cache::FileStore
    prepend ActiveSupport::Cache::Strategy::LocalCache
  end

  setup do
    install_wechat_stubs
    @a, @b = %w[clinic_login_a clinic_login_b].map do |id|
      App.create!(provider: "wechat", appid: id, status: "active", appsecret: SecureRandom.hex)
    end
    @openid = "fixture-openid"
    @phone = "10000000001"
    @country = "86"
    @exchanges = []
    @tokens = []
    @stubs.get("/sns/jscode2session") do |env|
      @exchanges << env.params.slice("appid", "secret", "grant_type")
      @during_login&.call
      assert_predicate env.params["js_code"], :present?
      response_for(openid: @openid, unionid: @unionid, session_key: "unused-test-value")
    end
    @stubs.post("/cgi-bin/stable_token") do |env|
      body = JSON.parse(env.body)
      @tokens << body.fetch("appid")
      response_for(access_token: "fixture-#{@tokens.size}", expires_in: 7200)
    end
    @stubs.post("/wxa/business/getuserphonenumber") do |env|
      assert_predicate JSON.parse(env.body).fetch("code"), :present?
      @used_token = env.params.fetch("access_token")
      @during_exchange&.call
      raise Faraday::TimeoutError if @timeout
      @phone_error ? response_for(errcode: @phone_error) : response_for(phone_info: {
        purePhoneNumber: @phone, countryCode: @country, watermark: { appid: @watermark || @a.appid }
      })
    end
  end
  teardown { remove_wechat_stubs }

  test "independent devices, cache clearing and application-bound revocation" do
    phone = login(@a, scene: "clinic-share")
    computer = login(@a)
    other = login(@b)
    refute_equal phone, computer
    binding = UserApp.for_app(@a).sole
    assert_equal [ Digest::SHA256.hexdigest(phone), Digest::SHA256.hexdigest(computer) ].sort, binding.sessions.keys.sort
    assert_in_delta 30.days.to_i, binding.sessions.values.first - Time.current.to_i, 2
    assert_equal "clinic-share", Log.find_by!(target_type: "UserApp", target_id: binding.id).details["scene"]
    assert_equal({ "appid" => @a.appid, "secret" => @a.appsecret, "grant_type" => "authorization_code" }, @exchanges.first)
    assert_empty @tokens
    Rails.cache.clear # This fixture installs a private MemoryStore.
    get api_mini_program_me_path(@b.appid), headers: bearer(phone)
    assert_response :unauthorized
    delete api_mini_program_session_path(@b.appid), headers: bearer(phone)
    assert_response :no_content
    assert_equal binding.user.user_no, me(@a, phone)["user_no"]
    delete api_mini_program_session_path(@a.appid), headers: bearer(phone)
    assert_response :no_content
    get api_mini_program_me_path(@a.appid), headers: bearer(phone)
    assert_response :unauthorized
    assert_equal binding.user.user_no, me(@a, computer)["user_no"]
    refute_equal binding.user.user_no, me(@b, other)["user_no"]
    assert_equal 2, binding.reload.sign_in_count
  end

  test "missing credentials and malformed identity fail before issuing any session" do
    token = login(@a)
    @a.update!(appsecret: nil)
    assert_predicate me(@a, token)["user_no"], :present?
    post api_mini_program_session_path(@a.appid), params: { code: "fixture" }, as: :json
    assert_response :service_unavailable
    assert_equal 1, @exchanges.size
    [ nil, {}, "  " ].each do |value|
      @openid = value
      post api_mini_program_session_path(@b.appid), params: { code: "fixture", openid: "ignored" }, as: :json
      assert_response :service_unavailable
    end
    assert_empty UserApp.for_app(@b)
    assert_equal 1, UserApp.for_app(@a).sole.sessions.size
  end

  test "trusted UnionID only links confirmed peers and never reassigns an existing binding" do
    @unionid = "union-fixture"
    a = login(@a)
    b = login(@b)
    user_a = UserApp.for_app(@a).sole.user
    user_b = UserApp.for_app(@b).sole.user
    refute_equal user_a, user_b
    [ user_a, user_b ].each { |user| user.update!(mobile: @phone, mobile_verified_at: Time.current) }
    c = App.create!(provider: "wechat", appid: "clinic_login_c", status: "active", appsecret: SecureRandom.hex)
    group = Setting.create!(key: "wechat", settings: { "unionid_app_groups" => [ [ @a.appid, c.appid ] ] })
    assert_equal user_a.user_no, me(c, login(c))["user_no"]
    group.update!(settings: { "unionid_app_groups" => [ [ @a.appid, @b.appid, c.appid ] ] })
    assert_equal user_b.user_no, me(@b, login(@b))["user_no"]
    @openid = "new-openid"
    post api_mini_program_session_path(@a.appid), params: { code: "fixture" }, as: :json
    assert_response :conflict
    assert_equal user_a.user_no, me(@a, a)["user_no"]
    assert_equal user_b.user_no, me(@b, b)["user_no"]
  end

  test "expiry and cleanup preserve other devices and their new sessions" do
    first = login(@a)
    travel 1.day
    second = login(@a)
    travel 29.days
    get api_mini_program_me_path(@a.appid), headers: bearer(first)
    assert_response :unauthorized
    assert_equal "session_expired", response.parsed_body.fetch("code")
    MiniProgramSessionsCleanupWorker.new.perform
    assert_equal [ Digest::SHA256.hexdigest(second) ], UserApp.for_app(@a).sole.sessions.keys
    me(@a, second)
  end

  test "private requests check app, binding and user on each call" do
    a, b = [ @a, @b ].map { |app| login(app) }
    binding = UserApp.for_app(@a).sole
    [ binding.user, binding ].each do |row|
      row.update!(status: "disabled")
      get api_mini_program_me_path(@a.appid), headers: bearer(a)
      assert_response :forbidden
      assert_equal "account_disabled", response.parsed_body["code"]
      post api_mini_program_session_path(@a.appid), params: { code: "fixture" }, as: :json
      assert_response :forbidden
      row.update!(status: "active")
    end
    @a.update!(status: "disabled")
    get api_mini_program_me_path(@a.appid), headers: bearer(a)
    assert_response :forbidden
    assert_equal({ "provider" => "wechat", "appid" => @a.appid, "status" => "disabled" }, response.parsed_body)
    me(@b, b)
  end

  test "booking policy and verified account mobile come from the server, independent of the contact" do
    token = login(@a)
    assert_equal false, me(@a, token)["booking_phone_required"]
    Setting.create!(key: "appointment", settings: { require_mobile_auth: true })
    assert_equal true, me(@a, token)["booking_phone_required"]
    other = login(@b)
    bind(@a, token, mobile: "10000000009", user_no: me(@b, other)["user_no"])
    assert_response :success
    assert_equal @phone, response.parsed_body["mobile"]
    assert_equal false, response.parsed_body["booking_phone_required"]
    assert_predicate UserApp.for_app(@a).sole.user.mobile_verified_at, :present?
    assert_nil me(@b, other)["mobile"]
    @watermark = @b.appid
    @phone = "10000000002"
    bind(@a, token)
    assert_response :service_unavailable
    assert_equal "10000000001", me(@a, token)["mobile"]
    @watermark = @a.appid
    @phone = "1234"
    bind(@a, token)
    assert_response :service_unavailable
    assert_equal "10000000001", me(@a, token)["mobile"]
    @timeout = true
    bind(@a, token)
    assert_response :service_unavailable
    assert_equal "10000000001", me(@a, token)["mobile"]
    assert_equal [ @a.appid ], @tokens
  end

  test "WeChat numeric country codes bind the same verified number as string codes" do
    token = login(@a)
    @country = 86
    bind(@a, token)
    assert_response :success
    assert_equal @phone, response.parsed_body.fetch("mobile")
    @country, @phone = 1, "2025550100"
    bind(@a, token)
    assert_response :success
    assert_equal "+12025550100", response.parsed_body.fetch("mobile")
    @country = 86.5
    bind(@a, token)
    assert_response :service_unavailable
    assert_equal "+12025550100", me(@a, token)["mobile"]
  end

  test "a failed entry log leaves the committed login usable" do
    Log.connection.add_check_constraint(:logs, "action <> 'mini_program.entry'", name: "reject_test_entry", validate: false)
    token = login(@a, scene: "clinic-share")
    assert_equal UserApp.for_app(@a).sole.user.user_no, me(@a, token)["user_no"]
    post api_mini_program_entry_scenes_path(@a.appid), headers: bearer(token), params: { scene: "clinic-share" }, as: :json
    assert_response :service_unavailable
    assert_equal 0, Log.where(action: "mini_program.entry").count
  end

  test "a logout receipt can only revoke the issuing device under its own application" do
    phone = login(@a)
    receipt = response.parsed_body.fetch("logout_token")
    computer = login(@a)
    get api_mini_program_me_path(@a.appid), headers: bearer(receipt)
    assert_response :unauthorized
    delete api_mini_program_session_path(@b.appid), headers: bearer(receipt)
    assert_response :no_content
    me(@a, phone)
    2.times do
      delete api_mini_program_session_path(@a.appid), headers: bearer(receipt)
      assert_response :no_content
    end
    get api_mini_program_me_path(@a.appid), headers: bearer(phone)
    assert_response :unauthorized
    me(@a, computer)
  end

  test "an exchange crossing a sharing change cannot restore a UnionID from the previous platform" do
    group = Setting.create!(key: "wechat", settings: { "unionid_app_groups" => [ [ @a.appid, @b.appid ] ] })
    @unionid = "fixture-before-transfer"
    original = login(@a)
    @during_login = -> { group.update!(settings: { "unionid_app_groups" => [] }) }
    post api_mini_program_session_path(@a.appid), params: { code: SecureRandom.hex }, as: :json
    assert_response :service_unavailable
    assert_equal 1, UserApp.for_app(@a).sole.sessions.size
    @during_login = nil
    @unionid = "fixture-after-transfer"
    assert_equal me(@a, original)["user_no"], me(@a, login(@a))["user_no"]
    assert_equal @unionid, UserApp.for_app(@a).sole.unionid
  end

  test "explicit WeChat rejection evicts only the token used, including during secret rotation" do
    a, b = [ @a, @b ].map { |app| login(app) }
    @watermark = @b.appid
    bind(@b, b)
    assert_response :success
    b_token = @used_token
    @phone_error = 42001
    bind(@a, a)
    assert_response :bad_gateway
    assert_nil Rails.cache.read(direct_token_key(@a))
    @during_exchange = lambda do
      @a.update!(appsecret: SecureRandom.hex)
      @new_token = Wechat::AccessToken.new(@a).fetch
    end
    bind(@a, a)
    assert_response :bad_gateway
    refute_equal @used_token, @new_token
    assert_equal @new_token, Rails.cache.read(direct_token_key(@a))
    assert_equal b_token, Rails.cache.read(direct_token_key(@b))
    me(@a, a)
    me(@b, b)
  end

  test "a revoked session cannot finish a pending phone exchange" do
    token = login(@a)
    @during_exchange = -> { MiniProgramSession.new(@a, token).revoke! }
    bind(@a, token)
    assert_response :unauthorized
    assert_nil UserApp.for_app(@a).sole.user.mobile_verified_at
  end

  test "a late rejection compares with the shared cache despite a stale request-local read" do
    Dir.mktmpdir do |directory|
      Rails.cache = RequestCache.new(directory)
      other_process = ActiveSupport::Cache::FileStore.new(directory)
      key = direct_token_key(@a)
      access = Wechat::AccessToken.new(@a)
      used = access.fetch
      replacement = SecureRandom.hex
      Rails.cache.with_local_cache do
        assert_equal used, Rails.cache.read(key)
        other_process.write(key, replacement)
        assert_equal used, Rails.cache.read(key)
        access.expire(used)
      end
      assert_equal replacement, other_process.read(key)
      assert_nil other_process.read("#{key}/rejected")
    end
  end

  private

  def bearer(token) = { "Authorization" => "Bearer #{token}" }

  def login(app, **params)
    post api_mini_program_session_path(app.appid), params: { code: SecureRandom.hex, **params }, as: :json
    assert_response :created
    assert_equal %w[expires_at logout_token token], response.parsed_body.keys.sort
    response.parsed_body.fetch("token")
  end

  def me(app, token)
    get api_mini_program_me_path(app.appid), headers: bearer(token)
    assert_response :success
    response.parsed_body
  end

  def bind(app, token, **params)
    post api_mini_program_phone_binding_path(app.appid), headers: bearer(token), params: { code: SecureRandom.hex, **params }, as: :json
  end
end
