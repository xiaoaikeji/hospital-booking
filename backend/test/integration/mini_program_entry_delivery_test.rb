require "test_helper"

class MiniProgramEntryDeliveryTest < ActionDispatch::IntegrationTest
  setup do
    @mini_app = App.create!(provider: "wechat", appid: "fixture_entry_delivery", status: "active")
    @binding = UserApp.create!(app: @mini_app, user: User.create!(platform: "wechat"), openid: "fixture-entry")
    @token = MiniProgramSession.issue!(@binding).fetch(:token)
    @source = { launch_scene: 1047, channel_scene: "门诊大厅", entry_id: SecureRandom.uuid, intended_user_no: @binding.user.user_no }
    @events = Log.where(action: "mini_program.entry", target_type: "UserApp", target_id: @binding.id)
  end

  test "a storage failure can be retried and a lost acknowledgement does not duplicate the first scan" do
    Log.connection.add_check_constraint(:logs, "action <> 'mini_program.entry'", name: "reject_entry_delivery_test", validate: false)
    deliver(@source)
    assert_response :service_unavailable
    assert_empty @binding.reload.first_entry
    Log.connection.remove_check_constraint(:logs, name: "reject_entry_delivery_test")

    assert_difference -> { @events.count }, 1 do
      2.times do
        deliver(@source)
        assert_response :no_content
      end
    end
    assert_equal @source.fetch(:entry_id), @events.sole.correlation_id
    deliver({ launch_scene: 1089, entry_id: SecureRandom.uuid, intended_user_no: @binding.user.user_no })
    assert_response :no_content
    assert_equal({ "launch_scene" => 1047, "channel_scene" => "门诊大厅" }, @binding.reload.first_entry)
    assert_equal [ 1047, 1089 ], @events.order(:id).map { |event| event.details.fetch("launch_scene") }
  end

  test "the authenticated account must match the intended owner before recording any source" do
    other = User.create!(platform: "wechat")
    assert_no_difference -> { @events.count } do
      deliver(@source.merge(intended_user_no: other.user_no))
      assert_response :conflict
      assert_equal "entry_account_changed", response.parsed_body.fetch("code")
      deliver(@source.merge(entry_id: "invalid"))
      assert_response :unprocessable_content
    end
    assert_empty @binding.reload.first_entry
  end

  private

  def deliver(context)
    post api_mini_program_entry_scenes_path(@mini_app.appid), headers: { "Authorization" => "Bearer #{@token}" },
      params: context, as: :json
  end
end
