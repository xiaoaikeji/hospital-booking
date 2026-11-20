class OfficialAccountFan < ApplicationRecord
  belongs_to :user_app
  scope :for_app, ->(app) { joins(:user_app).merge(UserApp.for_app(app)) }

  SCENES = {
    "ADD_SCENE_SEARCH" => "搜索公众号", "ADD_SCENE_ACCOUNT_MIGRATION" => "公众号迁移",
    "ADD_SCENE_PROFILE_CARD" => "名片分享", "ADD_SCENE_QR_CODE" => "扫二维码",
    "ADD_SCENE_PROFILE_LINK" => "文章内名称", "ADD_SCENE_PROFILE_ITEM" => "文章右上角菜单",
    "ADD_SCENE_PAID" => "支付后关注", "ADD_SCENE_WECHAT_ADVERTISEMENT" => "微信广告",
    "ADD_SCENE_REPRINT" => "他人转载", "ADD_SCENE_LIVESTREAM" => "视频号直播",
    "ADD_SCENE_CHANNELS" => "视频号", "ADD_SCENE_WXA" => "小程序关注", "ADD_SCENE_OTHERS" => "其他"
  }.freeze

  def channel
    qr_scene.presence || SCENES.fetch(scene, scene)
  end

  def supersedes?(time, event:, subscribed:)
    return observed_at >= time || updated_at >= time unless event
    return true if observed_at.to_i > time.to_i
    # 微信回调只精确到秒。同秒相互矛盾时以取关为准，重复推送不覆盖历史。
    event_at && (event_at > time || (event_at == time && (!subscribed? || subscribed)))
  end
end
