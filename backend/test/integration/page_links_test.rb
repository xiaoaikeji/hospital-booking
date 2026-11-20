require "test_helper"

class PageLinksTest < ActionDispatch::IntegrationTest
  test "each location inherits independently and an entirely disabled override stays empty" do
    sign_in_as("super_admin")
    first = App.create!(provider: "wechat", appid: "wx-page-a", nickname: "App A", status: "auditing")
    second = App.create!(provider: "wechat", appid: "wx-page-b", nickname: "App B", status: "active")
    common_one = create_banner("通用一")
    common_two = create_banner("通用二")
    menu_items = %w[预约记录 意见反馈 了解我院].map { |name| Link.create!(position: "profile_menu", name:).id }

    get admins_page_links_path(app_id: first.id)
    assert_select ".card-title .badge", text: "跟随通用"
    assert_select "table tbody a", text: "编辑", count: 0
    override = create_banner("专属轮播", app: first)

    first_config = config(first)
    assert_equal "auditing", first_config.fetch("status")
    assert_equal "App A", first_config.fetch("nickname")
    banner = first_config.dig("links", "home_banner").sole
    assert_equal override.id, banner.fetch("id")
    assert_equal menu_items, ids(first_config, "profile_menu")
    second_config = config(second)
    assert_equal [ common_one.id, common_two.id ], ids(second_config, "home_banner")
    assert_equal menu_items, ids(second_config, "profile_menu")

    image_path = URI.parse(banner.fetch("image_url")).path
    get image_path
    assert_response :ok
    assert_equal "image/jpeg", response.media_type
    get image_path.sub(first.appid, second.appid)
    assert_response :not_found

    patch admins_page_link_path(common_two), params: { link: { name: "调整轮播", link_type: "none", sort_order: -1 } }
    assert_response :see_other
    assert_equal [ override.id ], ids(config(first), "home_banner")
    assert_equal [ common_two.id, common_one.id ], ids(config(second), "home_banner")
    assert_equal "调整轮播", json_response.dig("links", "home_banner", 0, "name")

    delete admins_app_path(first)
    assert_redirected_to admins_app_path(first)
    assert_equal first.id, override.reload.app_id
    assert_match(/专属页面配置/, flash[:alert])

    patch status_admins_page_link_path(override), params: { status: "disabled" }
    assert_response :see_other
    assert_empty ids(config(first), "home_banner")
    assert_equal menu_items, ids(json_response, "profile_menu")
    assert_equal [ common_two.id, common_one.id ], ids(config(second), "home_banner")
    get image_path
    assert_response :not_found

    patch status_admins_page_link_path(override), params: { status: "active" }
    assert_response :see_other
    assert_equal [ override.id ], ids(config(first), "home_banner")
    get admins_page_links_path(app_id: first.id)
    assert_select ".card-title .badge", text: "使用专属配置"
    assert_includes css_select("#delete_link_#{override.id}-confirmation-description").text, "删除后，此位置将恢复通用配置"
    assert_no_difference "Link.count" do
      delete admins_page_link_path(override)
      assert_match(/重新确认/, flash[:alert])
    end
    delete admins_page_link_path(override), params: { restore_shared: "1" }
    assert_response :see_other
    assert_equal [ common_two.id, common_one.id ], ids(config(first), "home_banner")
    assert_equal menu_items, ids(json_response, "profile_menu")
    assert_equal %w[link.create link.disable link.enable link.destroy], Log.where(target_type: "Link", target_id: override.id, status: "success").order(:id).pluck(:action)
    assert_equal %w[link.create link.reorder link.update], Log.where(target_type: "Link", target_id: common_two.id).order(:id).pluck(:action)

    first.update!(status: "disabled")
    get api_app_configuration_path(first.provider, first.appid)
    assert_response :forbidden
    assert_equal({ "provider" => "wechat", "appid" => first.appid, "nickname" => "App A", "status" => "disabled" }, json_response)
    douyin = App.create!(provider: "douyin", appid: "tt-page-a", status: "active")
    assert_equal({ "home_banner" => [], "profile_menu" => [] }, config(douyin).fetch("links"))
  end

  test "page configuration reads and writes require a super administrator" do
    link = Link.create!(position: "profile_menu", name: "通用菜单")
    %w[operator customer_service].each do |role|
      sign_in_as(role)
      follow_redirect!
      assert_select "#sidebar-menu a", text: "小程序页面配置", count: 0

      [ admins_page_links_path, new_admins_page_link_path, edit_admins_page_link_path(link), image_admins_page_link_path(link) ].each do |path|
        get path
        assert_response :forbidden
      end
      assert_no_changes -> { [ Link.count, link.reload.attributes ] } do
        post admins_page_links_path(position: "profile_menu"), params: { link: { name: "无权创建" } }
        assert_response :forbidden
        patch admins_page_link_path(link), params: { link: { name: "无权编辑" } }
        assert_response :forbidden
        patch status_admins_page_link_path(link), params: { status: "disabled" }
        assert_response :forbidden
        delete admins_page_link_path(link)
        assert_response :forbidden
      end
      delete destroy_admin_session_path
    end
  end

  test "destination validation keeps page and tab routes distinct and accepts the implemented platform actions" do
    sign_in_as("super_admin")
    %w[page tab webview miniprogram].zip([
      { url: "/pages/booking/index" }, { url: "/pages/ucenter/feedback" },
      { url: "http://example.com" }, { url: "pages/index/index" }
    ]).each do |type, destination|
      assert_no_difference "Link.count" do
        post admins_page_links_path(position: "profile_menu"), params: { link: { name: type, link_type: type, **destination } }
        assert_response :unprocessable_content
      end
    end

    {
      "none" => {}, "contact" => {}, "page" => { url: "/pages/ucenter/feedback" }, "tab" => { url: "/pages/booking/index" },
      "webview" => { url: "https://example.com/guide" },
      "miniprogram" => { url: "pages/index/index", target_appid: "wx-target-app", page_query: "from=profile_menu&sort=recent" }
    }.each do |type, destination|
      post admins_page_links_path(position: "profile_menu"), params: { link: { name: type, link_type: type, **destination } }
      assert_response :see_other
    end
    assert_equal({ "target_appid" => "wx-target-app", "query" => { "from" => "profile_menu", "sort" => "recent" } }, Link.find_by!(link_type: "miniprogram").params)

    post admins_page_links_path, params: { link: { name: "无图轮播", link_type: "none" } }
    assert_response :unprocessable_content
    assert_select "#image-error", text: "请上传轮播图"
  end

  test "seeding twice keeps the original records and does not bring back deleted defaults" do
    load Rails.root.join("db/seeds.rb")
    assert_equal [ 1, 3 ], Link.where(app_id: nil).group(:position).count.values_at("home_banner", "profile_menu")
    assert Link.all.all? { |link| link.image.attached? }

    assert_no_difference [ "Link.count", "ActiveStorage::Blob.count" ] do
      PageLinkSeeds.load!
    end
    Link.destroy_all
    assert_no_difference [ "Link.count", "ActiveStorage::Blob.count" ] do
      PageLinkSeeds.load!
    end
  end

  private

  def sign_in_as(role)
    admin = Admin.create!(username: role, role:)
    post admin_session_path, params: { admin: { username: admin.username, password: "123456" } }
    assert_redirected_to admins_root_path
  end

  def create_banner(name, app: nil)
    image = fixture_file_upload(Rails.root.join("db/seeds/page_link_images/registration-banner.jpg"), "image/jpeg")
    post admins_page_links_path(app_id: app&.id, position: "home_banner"), params: { link: { name:, link_type: "none", image: } }
    assert_response :see_other
    Link.find_by!(name:)
  end

  def config(app)
    get api_app_configuration_path(app.provider, app.appid)
    assert_response :ok
    assert_equal "no-store", response.headers["Cache-Control"]
    json_response
  end

  def ids(configuration, position) = configuration.dig("links", position).pluck("id")
  def json_response = response.parsed_body
end
