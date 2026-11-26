require "test_helper"

class HospitalProfileTest < ActionDispatch::IntegrationTest
  test "hospital settings publish only the clinic profile and log changed fields" do
    admin = Admin.create!(username: "hospital_admin", role: "super_admin")
    post admin_session_path, params: { admin: { username: admin.username, password: Admin::DEFAULT_PASSWORD } }
    assert_redirected_to admins_root_path
    get edit_admins_system_settings_hospital_path
    assert_response :success
    assert_select "input[name='hospital[address]']"
    assert_select "#hospital_show_phone_on_homepage:not([checked])"

    record = Setting.create!(key: "hospital", settings: { "unrelated_key" => "internal-only-value" })
    app = App.create!(provider: "wechat", app_type: "mini_program", appid: "wxhospitaldemo", nickname: "小艾预约挂号小程序", status: "active")
    config_path = api_app_configuration_path(app.provider, app.appid)
    patch admins_system_settings_hospital_path, params: { hospital: { company_name: "示例医院",
      address: "门诊楼一号入口", mobile: "010-00000000", time_range: "周一至周六 08:00–17:30",
      introduction: "医院介绍", announcement: "门诊通知\r\n请提前取号",
      show_phone_on_homepage: "1", image: fixture_file_upload("storage.png", "image/png") } }
    assert_redirected_to edit_admins_system_settings_hospital_path
    follow_redirect!
    assert_response :success
    assert_select "input[name='hospital[remove_image]']"

    get config_path
    assert_response :success
    assert_equal "小艾预约挂号小程序", response.parsed_body.fetch("nickname")
    profile = response.parsed_body.fetch("hospital")
    assert_equal "示例医院", profile.fetch("company_name")
    assert_equal "门诊楼一号入口", profile.fetch("address")
    assert_equal "010-00000000", profile.fetch("mobile")
    assert_equal "周一至周六 08:00–17:30", profile.fetch("time_range")
    assert_equal "医院介绍", profile.fetch("introduction")
    assert_equal "门诊通知\n请提前取号", profile.fetch("announcement")
    assert_equal true, profile.fetch("show_phone_on_homepage")
    assert_not_includes response.body, "internal-only-value"
    assert_equal "internal-only-value", record.reload.settings.fetch("unrelated_key")
    image_path = URI(profile.fetch("image_url")).path
    get image_path
    assert_response :success
    assert_equal "image/png", response.media_type

    patch admins_system_settings_hospital_path, params: { hospital: { address: "门诊楼二号入口" } }
    assert_redirected_to edit_admins_system_settings_hospital_path
    get config_path
    assert_equal profile.merge("address" => "门诊楼二号入口"), response.parsed_body.fetch("hospital")
    log = Log.where(action: "hospital.update", status: "success").order(:id).last
    assert_equal [ admin.id, "Setting", record.id, { "fields" => [ "address" ] } ],
      [ log.actor_id, log.target_type, log.target_id, log.details ]
    get admins_operation_log_path(log)
    assert_select "dd", text: "address"

    patch admins_system_settings_hospital_path, params: { hospital: { announcement: " \n", show_phone_on_homepage: "0" } }
    assert_redirected_to edit_admins_system_settings_hospital_path
    get config_path
    profile = response.parsed_body.fetch("hospital")
    assert_not profile.key?("announcement")
    assert_equal [ "010-00000000", false ], profile.values_at("mobile", "show_phone_on_homepage")
    assert_equal %w[announcement show_phone_on_homepage], Log.where(action: "hospital.update").last.details.fetch("fields")

    app.update!(status: "disabled")
    get config_path
    assert_response :forbidden
    assert_not response.parsed_body.key?("hospital")
    get image_path
    assert_response :forbidden
  end

  test "hospital text can be saved with invalid storage while image uploads report failure" do
    admin = Admin.create!(username: "hospital_admin", role: "super_admin")
    post admin_session_path, params: { admin: { username: admin.username, password: Admin::DEFAULT_PASSWORD } }
    Setting.create!(key: "active_storage", settings: { "service" => "invalid" })

    patch admins_system_settings_hospital_path, params: { hospital: { address: "门诊楼一号入口" } }
    assert_redirected_to edit_admins_system_settings_hospital_path
    follow_redirect!
    assert_response :success

    record = HospitalProfile.load_record
    assert_equal "门诊楼一号入口", record.settings.fetch("address")
    assert_equal({ "fields" => [ "address" ] }, Log.find_by!(action: "hospital.update", target_id: record.id, status: "success").details)

    patch admins_system_settings_hospital_path, params: { hospital: {
      address: "门诊楼二号入口", image: fixture_file_upload("storage.png", "image/png")
    } }
    assert_response :service_unavailable
    assert_equal "门诊楼一号入口", record.reload.settings.fetch("address")
    assert_not record.hospital_image.attached?
    assert_equal [ "success", "failed" ], Log.where(action: "hospital.update", target_id: record.id).order(:id).pluck(:status)
  end

  test "only a complete saved map point is public and reopening the edit form retains it" do
    admin = Admin.create!(username: "hospital_admin", role: "super_admin")
    post admin_session_path, params: { admin: { username: admin.username, password: Admin::DEFAULT_PASSWORD } }
    app = App.create!(provider: "wechat", appid: "hospital-map-demo", status: "active")
    config_path = api_app_configuration_path(app.provider, app.appid)
    longitude = 116.403988
    latitude = 39.914266

    patch admins_system_settings_hospital_path, params: { hospital: {
      address: "验收门诊入口", address_longitude: longitude.to_s, address_latitude: latitude.to_s
    } }
    assert_redirected_to edit_admins_system_settings_hospital_path
    follow_redirect!
    assert_select "#hospital_address_longitude[value=?][disabled]", longitude.to_s
    assert_select "#hospital_address_latitude[value=?][disabled]", latitude.to_s
    assert_equal %w[address address_longitude address_latitude], Log.where(action: "hospital.update").last.details.fetch("fields")

    patch admins_system_settings_hospital_path, params: { hospital: { address: "二号入口", address_latitude: "91", address_longitude: longitude } }
    assert_response :unprocessable_content
    get config_path
    profile = response.parsed_body.fetch("hospital")
    assert_equal [ "验收门诊入口", longitude, latitude ], profile.values_at("address", "address_longitude", "address_latitude")

    patch admins_system_settings_hospital_path, params: { hospital: { address_longitude: "", address_latitude: "" } }
    assert_redirected_to edit_admins_system_settings_hospital_path
    get config_path
    profile = response.parsed_body.fetch("hospital")
    assert_equal "验收门诊入口", profile.fetch("address")
    assert_empty profile.slice("address_latitude", "address_longitude")
  end

  test "operators cannot access hospital settings or their image directly" do
    admin = Admin.create!(username: "hospital_operator", role: "operator")
    post admin_session_path, params: { admin: { username: admin.username, password: Admin::DEFAULT_PASSWORD } }
    get edit_admins_system_settings_hospital_path
    assert_response :forbidden
    get image_admins_system_settings_hospital_path
    assert_response :forbidden
    assert_no_changes -> { Setting.where(key: HospitalProfile::KEY).count } do
      patch admins_system_settings_hospital_path, params: { hospital: { company_name: "无权限修改" } }
      assert_response :forbidden
    end
  end
end
