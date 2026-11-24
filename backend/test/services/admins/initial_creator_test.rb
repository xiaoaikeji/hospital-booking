# frozen_string_literal: true

require "test_helper"
require "stringio"

class AdminsInitialCreatorTest < ActiveSupport::TestCase
  test "production rejects missing, blank, and default passwords without creating admin" do
    [
      [ {}, "" ],
      [ { "ADMIN_PASSWORD" => "" }, "" ],
      [ { "ADMIN_PASSWORD" => "   " }, "" ],
      [ {}, "   \n" ],
      [ { "ADMIN_PASSWORD" => Admin::DEFAULT_PASSWORD }, "" ],
      [ {}, "#{Admin::DEFAULT_PASSWORD}\n" ]
    ].each do |env, stdin_text|
      out = StringIO.new
      err = StringIO.new
      assert_no_difference "Admin.count" do
        error = assert_raises(Admins::InitialCreator::Error) do
          Admins::InitialCreator.new(
            env:,
            input: StringIO.new(stdin_text),
            output: out,
            error_output: err,
            production: true
          ).call
        end
        assert_not_includes error.message, Admin::DEFAULT_PASSWORD
      end
      assert_empty out.string
    end
  end

  test "production creates super admin with explicit stdin password without echoing password" do
    secret = "Hospital#Adm1n!2026"
    out = StringIO.new
    err = StringIO.new

    admin = assert_difference "Admin.count", 1 do
      Admins::InitialCreator.new(
        env: { "ADMIN_USERNAME" => "hosp_admin" },
        input: StringIO.new("#{secret}\n"),
        output: out,
        error_output: err,
        production: true
      ).call
    end

    assert_equal "hosp_admin", admin.username
    assert admin.super_admin?
    assert admin.valid_password?(secret)
    assert_not admin.valid_password?(Admin::DEFAULT_PASSWORD)
    assert_not_includes out.string, secret
    assert_not_includes err.string, secret
    assert_not_includes Log.last.attributes.to_json, secret
  end

  test "blocks creation and preserves password when an admin already exists" do
    existing = Admin.create!(username: "root_admin", password: "Existing#Pass99", role: "super_admin")
    out = StringIO.new

    assert_no_difference "Admin.count" do
      error = assert_raises(Admins::InitialCreator::Error) do
        Admins::InitialCreator.new(
          env: { "ADMIN_PASSWORD" => "Another#Pass88" },
          input: StringIO.new(""),
          output: out,
          error_output: StringIO.new,
          production: true
        ).call
      end
      assert_includes error.message, "管理员已存在"
    end

    assert existing.reload.valid_password?("Existing#Pass99")
    assert_not existing.valid_password?("Another#Pass88")
  end

  test "non-production preserves default password fallback" do
    admin = Admins::InitialCreator.new(
      env: {},
      input: StringIO.new(""),
      output: StringIO.new,
      error_output: StringIO.new,
      production: false
    ).call

    assert_equal "admin", admin.username
    assert admin.valid_password?(Admin::DEFAULT_PASSWORD)
  end
end
