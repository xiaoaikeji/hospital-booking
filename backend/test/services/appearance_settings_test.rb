require "test_helper"

class AppearanceSettingsTest < ActiveSupport::TestCase
  # 模拟迁移前已启动的进程：SELECT * 能读到新列，但更新列表尚未包含它。
  class AdminWithOldSchema < Admin
    def self.column_names = super - [ "appearance_overrides" ]
  end

  test "a skipped preference write cannot report a successful save" do
    actor = Admin.create!(username: "old_schema_admin")
    settings = AppearanceSettings.new(admin: AdminWithOldSchema.find(actor.id))
    revision = settings.revision

    assert_no_difference -> { Log.where(action: "personal_appearance.update", status: "success").count } do
      assert_not settings.save({ "theme_primary" => "red" }, expected_revision: revision, actor: actor, request: nil)
    end
    assert_includes settings.errors[:base].join, "未保存"
    assert_empty actor.reload.appearance_overrides
    assert_equal revision, settings.revision
  end
end
