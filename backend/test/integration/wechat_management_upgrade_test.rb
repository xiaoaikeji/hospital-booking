require "test_helper"
require Rails.root.join("db/migrate/20261120020000_track_wechat_management_requests")

class WechatManagementUpgradeTest < ActiveSupport::TestCase
  test "从旧库升级，回填最近受理的类目及可判定的插件请求，已删除、解除或重新申请的不再阻拦" do
    db = ApplicationRecord.connection
    db.transaction(requires_new: true) do
      namespace = "wechat_upgrade_#{SecureRandom.hex(5)}"
      db.execute("CREATE SCHEMA #{namespace}")
      db.execute("SET LOCAL search_path TO #{namespace}, public")
      db.execute("CREATE TABLE apps (id bigint PRIMARY KEY)")
      db.execute("CREATE TABLE logs (id bigserial PRIMARY KEY, action text, status text, category text, target_type text, target_id bigint, details jsonb, created_at timestamp)")
      db.execute("INSERT INTO apps VALUES (1),(2)")
      log = lambda do |app, action, status, details|
        db.execute("INSERT INTO logs(action,status,category,target_type,target_id,details,created_at)
          VALUES (#{db.quote("wechat.#{action}")},#{db.quote(status)},'wechat','App',#{app},#{db.quote(details.to_json)},now())")
      end
      log.call(1, "category_add", "success", {first: 10, second: 20})
      log.call(2, "category_add", "success", {first: 10, second: 20})
      log.call(2, "category_delete", "success", {first: 10, second: 20})
      log.call(1, "category_add", "failed", {first: 11, second: 30})
      log.call(1, "plugin_update", "success", {plugin_appid: "wxA", version: "1.2"})
      log.call(2, "plugin_update", "failed", {plugin_appid: "wxA", version: "2.0", reason: "微信尚未确认本次插件操作，请先核实当前插件状态"})
      log.call(1, "plugin_update", "success", {plugin_appid: "wxB", version: "1.2"})
      log.call(1, "plugin_unbind", "success", {plugin_appid: "wxB"})
      log.call(1, "plugin_update", "success", {plugin_appid: "wxC", version: "1.2"})
      log.call(1, "plugin_apply", "success", {plugin_appid: "wxC"})
      migration = TrackWechatManagementRequests.new
      migration.suppress_messages { migration.migrate(:up) }
      assert_equal [[1, 10, 20]], db.select_rows("SELECT app_id,first_category,second_category FROM wechat_category_acceptances")
      assert_equal [[1,"wxA","1.2",true], [2,"wxA","2.0",false]],
        db.select_rows("SELECT app_id,plugin_appid,version,confirmed FROM wechat_plugin_updates ORDER BY app_id")
      raise ActiveRecord::Rollback
    end
  end
end
