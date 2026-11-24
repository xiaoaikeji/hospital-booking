require "test_helper"
require_relative "../support/wechat_pay_protocol"

class WechatPaySettingsTest < ActionDispatch::IntegrationTest
  include WechatPayProtocol

  setup { generate_payment_keys }

  test "switching merchants shows blank credential fields and names the required materials" do
    admin = Admin.create!(username: "switch_merchant", role: "super_admin")
    post admin_session_path, params: { admin: { username: admin.username, password: Admin::DEFAULT_PASSWORD } }
    old = payment_settings("v3")
    platform = payment_certificate(@wechat_key, "Test Platform")
    old.merge!("verification_id" => platform.serial.to_s(16).upcase, "verification_pem" => platform.to_pem)
    settings = WechatPaySettings.new
    assert settings.save(old.merge("revision" => settings.revision), actor: admin)
    get edit_admins_system_settings_wechat_pay_path
    replacement = old.merge("merchant_id" => "1900000002", "v3_api_key" => SecureRandom.hex(16),
      "revision" => WechatPaySettings.new.revision)
    patch admins_system_settings_wechat_pay_path, params: { wechat_pay: replacement }
    assert_response :unprocessable_content
    assert_private_field "v3_api_key", "未配置"
    assert_select "input#wechat_pay_verification_id" do |inputs|
      assert_empty inputs.first["value"].to_s
      refute_match(/留空保留/, inputs.first["placeholder"])
    end
    assert_private_field "verification_pem", "未配置"
    assert_private_field "v3_private_key", "未配置"
    assert_no_payment_secrets(old.merge("replacement_key" => replacement.fetch("v3_api_key")))
    assert_select "[data-merchant-change]:not([hidden])", text: /新商户.*平台证书/m
    assert_equal @merchant_id, WechatPaySettings.new.value("merchant_id")
    generate_payment_keys
    new_fields = payment_settings("v3").merge("merchant_id" => "1900000002", "revision" => replacement.fetch("revision"),
      "backup_verification_id" => platform.serial.to_s(16).downcase, "backup_verification_pem" => platform.to_pem)
    patch admins_system_settings_wechat_pay_path, params: { wechat_pay: new_fields }
    assert_response :unprocessable_content
    assert_select "#backup_verification_id-error", text: /新商户/
    assert_private_field "backup_verification_pem", "未配置"
    assert_no_payment_secrets(new_fields.except("revision"))
    patch admins_system_settings_wechat_pay_path, params: { wechat_pay: new_fields.except(*WechatPaySettings::BACKUP) }
    assert_redirected_to edit_admins_system_settings_wechat_pay_path
    assert_equal "1900000002", WechatPaySettings.new.material!.fetch("merchant_id")
  end

  test "a backup PEM without its ID can be disabled from the form after a failed save" do
    field = "WECHAT_PAY_BACKUP_VERIFICATION_PEM"
    previous = ENV[field]
    ENV[field] = OpenSSL::PKey::RSA.generate(2048).public_key.to_pem
    admin = Admin.create!(username: "disable_backup", role: "super_admin")
    post admin_session_path, params: { admin: { username: admin.username, password: Admin::DEFAULT_PASSWORD } }
    input = payment_settings("v3").merge("revision" => WechatPaySettings.new.revision)
    patch admins_system_settings_wechat_pay_path, params: { wechat_pay: input }
    assert_response :unprocessable_content
    assert_select "#backup_verification_id-error"
    assert_select "[aria-controls=wechat-pay-backup][aria-expanded=true]"
    assert_select "#wechat-pay-backup.collapse.show input#wechat_pay_remove_backup[type=checkbox]"
    patch admins_system_settings_wechat_pay_path, params: { wechat_pay: input.merge("remove_backup" => "1") }
    assert_redirected_to edit_admins_system_settings_wechat_pay_path
    assert_nil WechatPaySettings.new.material!["backup_verification_pem"]
  ensure
    ENV[field] = previous
  end

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

  test "blank passwords retain active keys and pasted PEM works across invalid or stale saves and clearing" do
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
    v2["v2_api_key"] = v2["v2_certificate"] = ""
    v2["v2_private_key"] = v2.fetch("v2_private_key").tr("\n", " ")
    patch admins_system_settings_wechat_pay_path, params: { wechat_pay: v2.merge("revision" => revision) }
    assert_redirected_to edit_admins_system_settings_wechat_pay_path
    follow_redirect!
    assert_private_field "v2_api_key", "已配置"
    assert_private_field "v2_private_key", "已配置"
    assert_no_payment_secrets(payment_settings("v2"))
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
    unsafe_origin = "https://booking.example.org/?key=payment-origin-fixture-only"
    patch admins_system_settings_wechat_pay_path, params: { wechat_pay: payment_settings("v3").merge("revision" => first_revision, "notify_origin" => unsafe_origin) }
    assert_response :unprocessable_content
    assert_not_includes response.body, "payment-origin-fixture-only"
    assert_no_payment_secrets(payment_settings("v3"))
    assert_equal "v2", WechatPaySettings.new.value("version")
    patch admins_system_settings_wechat_pay_path, params: { wechat_pay: { revision: first_revision, version: "v3" } }
    assert_response :unprocessable_content
    assert_select ".invalid-feedback", text: /APIv3/
    assert_equal "v2", WechatPaySettings.new.value("version")
    patch admins_system_settings_wechat_pay_path, params: { wechat_pay: payment_settings("v3").merge("revision" => first_revision) }
    assert_redirected_to edit_admins_system_settings_wechat_pay_path
    follow_redirect!
    assert_select "fieldset[data-payment-version=v2][hidden][disabled]"
    assert_private_field "v3_api_key", "已配置"
    assert_select "#wechat_pay_merchant_serial[value=?]", payment_settings("v3").fetch("merchant_serial")
    assert_no_payment_secrets(payment_settings("v3"))
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

  test "inherited backup is disabled on old references and an incomplete or mismatched pair shows its own field" do
    old_merchant = ENV["WECHAT_PAY_MERCHANT_ID"]
    old_id = ENV["WECHAT_PAY_BACKUP_VERIFICATION_ID"]
    old_pem = ENV["WECHAT_PAY_BACKUP_VERIFICATION_PEM"]
    ENV["WECHAT_PAY_BACKUP_VERIFICATION_ID"] = "PUB_KEY_ID_3000000001"
    ENV["WECHAT_PAY_BACKUP_VERIFICATION_PEM"] = OpenSSL::PKey::RSA.generate(2048).public_key.to_pem
    settings = WechatPaySettings.new
    assert settings.save(payment_settings("v3").merge("revision" => settings.revision), actor: nil)
    settings = WechatPaySettings.new
    ref = settings.reserve!.fetch("config_ref")
    assert_equal "环境变量", settings.source("backup_verification_id")
    assert settings.save({ "revision" => settings.revision, "remove_backup" => "1" }, actor: nil)
    assert_nil WechatPaySettings.fetch!(ref)["backup_verification_id"]
    v2 = payment_settings("v2")
    [ [ v2.except("v2_private_key"), "v2_private_key" ], [ v2.except("v2_certificate"), "v2_certificate" ],
      [ v2.merge("v2_private_key" => @wechat_key.to_pem), "v2_private_key" ] ].each do |input, field|
      settings = WechatPaySettings.new
      refute settings.save(input.merge("revision" => settings.revision), actor: nil)
      assert_predicate settings.errors[field], :present?
    end
    settings = WechatPaySettings.new
    assert settings.save(v2.merge("revision" => settings.revision), actor: nil)
    assert_nil WechatPaySettings.fetch!(ref)["backup_verification_id"]
    ENV["WECHAT_PAY_MERCHANT_ID"] = @merchant_id
    settings = WechatPaySettings.new
    assert settings.save({ "revision" => settings.revision, "clear_settings" => "1" }, actor: nil)
    assert WechatPaySettings::BACKUP.none? { |field| WechatPaySettings.fetch!(ref).key?(field) }
  ensure
    ENV["WECHAT_PAY_MERCHANT_ID"] = old_merchant
    ENV["WECHAT_PAY_BACKUP_VERIFICATION_ID"] = old_id
    ENV["WECHAT_PAY_BACKUP_VERIFICATION_PEM"] = old_pem
  end

  private

  def assert_private_field(field, status)
    assert_select "#wechat_pay_#{field}[type=password]:not([value])"
    assert_select "label[for=wechat_pay_#{field}] ~ [data-credential-status]", text: status
  end

  def assert_no_payment_secrets(values)
    values.except(*WechatPaySettings::PUBLIC_FIELDS).each_value do |value|
      value.lines.map(&:strip).reject(&:empty?).each { |part| assert_not_includes response.body, part }
    end
  end
end
