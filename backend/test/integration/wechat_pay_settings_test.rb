require "test_helper"
require_relative "../support/wechat_pay_protocol"

class WechatPaySettingsTest < ActionDispatch::IntegrationTest
  include WechatPayProtocol

  setup { generate_payment_keys }

  test "only a super admin sees the menu or can read or write the credentials" do
    %w[operator customer_service].each do |role|
      admin = Admin.create!(username: "payments_#{role}", role: role)
      post admin_session_path, params: { admin: { username: admin.username, password: Admin::DEFAULT_PASSWORD } }
      follow_redirect!
      assert_select "a[href=?]", edit_admins_system_settings_wechat_pay_path, count: 0
      get edit_admins_system_settings_wechat_pay_path
      assert_response :forbidden
      assert_no_changes -> { Setting.find_by(key: "wechat_pay")&.settings } do
        patch admins_system_settings_wechat_pay_path, params: { wechat_pay: payment_settings("v2") }
        assert_response :forbidden
      end
      delete destroy_admin_session_path
    end
  end

  test "active values and origins survive redisplay, invalid or stale saves, and clearing" do
    field = "WECHAT_PAY_V2_API_KEY"
    previous = ENV[field]
    previous_pem = ENV["WECHAT_PAY_V2_CERTIFICATE"]
    ENV[field] = @v2_key
    ENV["WECHAT_PAY_V2_CERTIFICATE"] = @certificate.to_pem
    admin = Admin.create!(username: "payments_settings", role: "super_admin")
    post admin_session_path, params: { admin: { username: admin.username, password: Admin::DEFAULT_PASSWORD } }
    get edit_admins_system_settings_wechat_pay_path
    assert_response :success
    assert_select "nav[aria-label='系统设置'] a[href=?] + a[href=?]", edit_admins_system_settings_appointment_path, edit_admins_system_settings_wechat_pay_path
    revision = css_select("#wechat_pay_revision").first["value"]
    v2 = payment_settings("v2")
    v2["v2_certificate"] = v2.fetch("v2_certificate").gsub("\n", "\r\n")
    patch admins_system_settings_wechat_pay_path, params: { wechat_pay: v2.merge("revision" => revision) }
    assert_redirected_to edit_admins_system_settings_wechat_pay_path
    follow_redirect!
    assert_select "input#wechat_pay_v2_api_key[value=?]", @v2_key
    assert_select "span[title=环境变量]"
    assert_select "fieldset[data-payment-version=v3][disabled][hidden]"
    settings = WechatPaySettings.new
    ref = settings.reserve!.fetch("config_ref")
    first_revision = settings.revision
    row = Setting.find_by!(key: "wechat_pay")
    refute row.settings.key?("v2_api_key")
    refute row.settings.key?("v2_certificate")
    assert_equal [ "ciphertext" ], row.settings.fetch("v2_private_key").keys
    assert_equal [ "ciphertext" ], Setting.find_by!(key: "wechat_pay_profile:#{ref}").settings.fetch("material").keys
    refute_includes Setting.where("key LIKE 'wechat_pay%'").pluck(:settings).to_json, "BEGIN"
    log = Log.find_by!(action: "wechat_pay.update", actor_type: "Admin", actor_id: admin.id)
    assert_equal [ "fields" ], log.details.keys
    assert_equal %w[version merchant_id notify_origin v2_private_key].sort, log.details.fetch("fields").sort
    refute_includes log.details.to_s, @v2_key
    patch admins_system_settings_wechat_pay_path, params: { wechat_pay: { revision: first_revision, version: "v3" } }
    assert_response :unprocessable_content
    assert_select ".alert-danger", text: /APIv3/
    assert_equal "v2", WechatPaySettings.new.value("version")
    patch admins_system_settings_wechat_pay_path, params: { wechat_pay: payment_settings("v3").merge("revision" => first_revision) }
    assert_redirected_to edit_admins_system_settings_wechat_pay_path
    follow_redirect!
    assert_select "fieldset[data-payment-version=v2][hidden][disabled]"
    assert_select "input#wechat_pay_v3_api_key[value=?]", @v3_key
    patch admins_system_settings_wechat_pay_path, params: { wechat_pay: { revision: first_revision, clear_settings: "1" } }
    assert_response :unprocessable_content
    assert_equal "v3", WechatPaySettings.new.value("version")
    patch admins_system_settings_wechat_pay_path, params: { wechat_pay: { revision: WechatPaySettings.new.revision, clear_settings: "1" } }
    assert_redirected_to edit_admins_system_settings_wechat_pay_path
    assert_empty row.reload.settings
    ENV[field] = SecureRandom.hex(16)
    assert_equal @v2_key, WechatPaySettings.fetch!(ref).fetch("v2_api_key")
    assert_raises(WechatPaySettings::Invalid) { WechatPaySettings.new.reserve! }
  ensure
    ENV[field] = previous
    ENV["WECHAT_PAY_V2_CERTIFICATE"] = previous_pem
  end

  test "keys, merchant certificate, platform verification material and origin are checked before switching" do
    valid = payment_settings("v3")
    platform = payment_certificate(@wechat_key, "Test WeChat")
    valid.merge!("verification_id" => platform.serial.to_s(16), "verification_pem" => platform.to_pem)
    settings = WechatPaySettings.new
    assert settings.save(valid.merge("revision" => settings.revision), actor: nil)
    settings = WechatPaySettings.new
    assert_equal platform.serial.to_s(16).upcase, settings.material!["verification_id"]
    [ { "verification_id" => "BAD" }, { "v3_api_key" => "short" }, { "notify_origin" => "http://example.org" },
      { "verification_pem" => @wechat_key.to_pem, "verification_id" => @key_id },
      payment_settings("v2").merge("merchant_id" => "12"),
      payment_settings("v2").merge("v2_private_key" => @wechat_key.to_pem) ].each do |invalid|
      refute settings.save(invalid.merge("revision" => settings.revision), actor: nil)
      assert_equal "v3", WechatPaySettings.new.value("version")
    end
  end
end
