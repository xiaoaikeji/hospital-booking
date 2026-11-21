require "test_helper"
require_relative "../support/wechat_http_test"
require_relative "../support/poster_files"

class PostersTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include WechatHttpTest
  include PosterFiles
  setup do
    install_wechat_stubs
    @admin = Admin.create!(username: "poster_admin", role: "super_admin")
    sign_in @admin
    @apps = %w[wxPosterA wxPosterB].map do |appid|
      app = App.create!(provider: "wechat", status: "active", appid: appid, nickname: appid)
      auth = app.create_app_authorization!(refresh_token: "local-refresh")
      Rails.cache.write("apps/#{app.id}/channel_token", { value: appid, revision: auth.updated_at.to_f })
      app
    end
  end
  teardown { remove_wechat_stubs }

  def target(app = @apps.first, query = "event_id=clinic")
    { target_kind: "mini_program", app_id: app.id, page_path: "pages/registration/index", page_query: query }
  end

  test "旧海报有确认入口，删除保留操作日志且限超级管理员" do
    file = poster_file
    post admins_posters_path, params: { poster: { name: "旧活动海报", background: Rack::Test::UploadedFile.new(file.tempfile.path, file.content_type) } }
    poster = Poster.sole
    get edit_admins_poster_path(poster)
    assert_select "button[data-bs-target='#delete-poster-confirmation']", "删除"
    assert_select "#delete-poster-confirmation [data-admin-confirm-form='delete-poster-form']", text: "确认删除"
    sign_in Admin.create!(username: "poster_ops", role: "operator")
    assert_no_difference "Poster.count" do
      delete admins_poster_path(poster)
      assert_response :forbidden
    end
    sign_in @admin
    assert_difference "Poster.count", -1 do
      delete admins_poster_path(poster)
      assert_redirected_to admins_posters_path
    end
    log = Log.operations_visible_to(@admin).find_by!(action: "poster.delete", target_id: poster.id)
    assert_equal @admin.id, log.actor_id
  end

  test "empty upload edit save and private background work without public storage URLs" do
    get admins_posters_path
    assert_response :success
    assert_select ".empty-title", "还没有海报"
    file = poster_file
    post admins_posters_path, params: { poster: { name: "社区义诊", background: Rack::Test::UploadedFile.new(file.tempfile.path, file.content_type) } }
    poster = Poster.last
    assert_redirected_to edit_admins_poster_path(poster)
    patch admins_poster_path(poster), params: { poster: target.merge(name: "社区义诊", qr_x: 550, qr_y: 950, qr_size: 200) }
    assert_redirected_to edit_admins_poster_path(poster)
    get edit_admins_poster_path(poster)
    assert_select "#poster_qr_x[value='550']"
    assert_select "#poster_page_query[value='event_id=clinic']"
    get background_admins_poster_path(poster)
    assert_response :success
    assert_equal "image/png", response.media_type
    assert_includes response.headers["Cache-Control"], "no-store"
    sign_out @admin
    get background_admins_poster_path(poster)
    assert_redirected_to new_admin_session_path
  end

  test "wide banner creation and smaller background replacement fit layout while manual invalid coordinates fail safely" do
    banner_file = poster_file(width: 2000, height: 100)
    post admins_posters_path, params: { poster: { name: "活动横幅", background: Rack::Test::UploadedFile.new(banner_file.tempfile.path, banner_file.content_type) } }
    banner = Poster.last
    assert_redirected_to edit_admins_poster_path(banner)
    assert_equal [ 2000, 100 ], [ banner.image_width, banner.image_height ]
    assert_operator banner.qr_y, :>=, 0
    assert_operator banner.qr_x + banner.qr_size, :<=, 2000
    assert_operator banner.qr_y + banner.qr_size, :<=, 100

    tall_file = poster_file(width: 1080, height: 1620)
    post admins_posters_path, params: { poster: { name: "竖版海报", background: Rack::Test::UploadedFile.new(tall_file.tempfile.path, tall_file.content_type) } }
    poster = Poster.last
    assert_redirected_to edit_admins_poster_path(poster)
    square_file = poster_file(width: 800, height: 800)
    patch admins_poster_path(poster), params: { poster: {
      name: poster.name, qr_x: poster.qr_x, qr_y: poster.qr_y, qr_size: poster.qr_size,
      background: Rack::Test::UploadedFile.new(square_file.tempfile.path, square_file.content_type)
    } }
    assert_redirected_to edit_admins_poster_path(poster)
    assert_equal [ 800, 800, 541, 541, 259 ], poster.reload.attributes.values_at("image_width", "image_height", "qr_x", "qr_y", "qr_size")

    original_blob = poster.background.blob
    another_file = poster_file(width: 600, height: 600)
    patch admins_poster_path(poster), params: { poster: {
      name: poster.name, qr_x: 790, qr_y: 541, qr_size: 259,
      background: Rack::Test::UploadedFile.new(another_file.tempfile.path, another_file.content_type)
    } }
    assert_response :unprocessable_content
    assert_includes response.body, "二维码必须完整放在底图内"
    assert_includes response.body, "原图 800 × 800 像素"
    assert_equal original_blob, poster.reload.background.blob
  end

  test "codes and caches isolate applications paths and query and reject revoked authorization" do
    requests = []
    @stubs.post("/wxa/getwxacode") do |env|
      body = JSON.parse(env.body)
      assert_equal "release", body["env_version"]
      assert_equal 1280, body["width"]
      requests << [ env.params["access_token"], body["path"] ]
      [ 200, { "Content-Type" => "image/png" }, File.binread(file_fixture("storage.png")) + env.params["access_token"] ]
    end
    [ target, target(@apps.last), target, target(@apps.first, "event_id=esports") ].each do |value|
      post admins_poster_code_path, params: { target: value }, as: :json
      assert_response :success
      assert_includes Base64.decode64(response.parsed_body["image"].split(",").last), App.find(value[:app_id]).appid
    end
    assert_equal [ [ "wxPosterA", "pages/registration/index?event_id=clinic" ], [ "wxPosterB", "pages/registration/index?event_id=clinic" ], [ "wxPosterA", "pages/registration/index?event_id=esports" ] ], requests
    @apps.first.app_authorization.update!(refresh_token: nil)
    post admins_poster_code_path, params: { target: target }, as: :json
    assert_response :unprocessable_content
    assert_equal 3, requests.size
  end

  test "existing official account code must belong to selected account" do
    official = App.create!(provider: "wechat", app_type: "official_account", status: "active", appid: "wxPosterOfficial")
    code = OfficialAccountQrcode.create!(app: official, name: "义诊报名", scene: "qd_123456abcdef", url: "https://weixin.qq.com/q/demo", ticket: "local-ticket")
    value = { target_kind: "official_account", app_id: official.id, official_account_qrcode_id: code.id }
    post admins_poster_code_path, params: { target: value }, as: :json
    assert_response :success
    assert_equal code.png, Base64.decode64(response.parsed_body["image"].split(",").last)
    post admins_poster_code_path, params: { target: value.merge(app_id: @apps.first.id) }, as: :json
    assert_response :unprocessable_content
  end

  test "WeChat errors do not persist or discard draft and retries can succeed" do
    calls = 0
    @stubs.post("/wxa/getwxacode") do
      calls += 1
      calls == 1 ? response_for(errcode: 45009) : [ 200, { "Content-Type" => "image/png" }, File.binread(file_fixture("storage.png")) ]
    end
    assert_no_difference "Poster.count" do
      post admins_poster_code_path, params: { target: target }, as: :json
      assert_response :unprocessable_content
      post admins_poster_code_path, params: { target: target }, as: :json
      assert_response :success
    end
    post admins_poster_code_path, params: { target: target.merge(page_path: "/bad") }, as: :json
    assert_response :unprocessable_content
    post admins_poster_code_path, params: { target: target.merge(page_query: "x=" + "a" * 128) }, as: :json
    assert_response :unprocessable_content
  end

  test "direct credential errors remain actionable and disabled apps cannot reuse cached images" do
    app = App.create!(provider: "wechat", status: "active", appid: "wxPosterDirect", appsecret: "local-direct-secret")
    calls = 0
    @stubs.post("/cgi-bin/stable_token") { response_for(access_token: "direct-poster") }
    @stubs.post("/wxa/getwxacode") do |env|
      calls += 1
      assert_equal "direct-poster", env.params["access_token"]
      [ 200, { "Content-Type" => "image/png" }, File.binread(file_fixture("storage.png")) ]
    end
    2.times do
      post admins_poster_code_path, params: { target: target(app) }, as: :json
      assert_response :success
    end
    assert_equal 1, calls
    app.update!(status: "disabled")
    post admins_poster_code_path, params: { target: target(app) }, as: :json
    assert_response :unprocessable_content
    app.update!(status: "active")
    App.connection.execute("UPDATE apps SET appsecret = 'broken-ciphertext' WHERE id = #{Integer(app.id)}")
    post admins_poster_code_path, params: { target: target(app) }, as: :json
    assert_response :unprocessable_content
    assert_includes response.parsed_body["error"], "解密失败"
    assert_equal 1, calls
  end

  test "non super administrators cannot see menu or directly use any poster endpoint" do
    poster = Poster.new
    PosterSaving.call(poster, attributes: { name: "义诊" }, file: poster_file, actor: @admin)
    %w[operator customer_service].each do |role|
      sign_in Admin.create!(username: "poster_#{role}", role: role)
      get admins_root_path
      assert_select "a[href=?]", admins_posters_path, count: 0
      [ admins_posters_path, new_admins_poster_path, edit_admins_poster_path(poster), background_admins_poster_path(poster) ].each do |path|
        get path
        assert_response :forbidden
      end
      post admins_posters_path, params: { poster: { name: "blocked" } }
      assert_response :forbidden
      patch admins_poster_path(poster), params: { poster: { name: "blocked" } }
      assert_response :forbidden
      post admins_poster_code_path, params: { target: target }, as: :json
      assert_response :forbidden
    end
  end
end
