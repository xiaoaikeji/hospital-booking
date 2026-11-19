module WechatPlatform
  class Error < StandardError; end

  def self.log!(app, action, actor:, request: nil, **options)
    return unless actor || action == "publish"
    event = actor ? "wechat.#{action}" : "wechat.auto_publish"
    Log.record!(source: actor ? "admin" : "system", category: "wechat", action: event,
      actor: actor, request: request, target: app, **options)
  end
end
