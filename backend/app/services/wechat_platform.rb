module WechatPlatform
  class Error < StandardError; end

  def self.log!(app, action, actor:, request: nil, **options)
    return unless actor
    Log.record!(category: "wechat", action: "wechat.#{action}", actor: actor, request: request, target: app, **options)
  end
end
