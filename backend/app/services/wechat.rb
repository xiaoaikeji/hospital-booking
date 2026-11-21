module Wechat
  class Error < StandardError; end

  def self.log!(app, action, actor:, request: nil, **options)
    Log.record!(source: "admin", category: "wechat", action: "wechat.#{action}",
      actor: actor, request: request, target: app, **options)
  end
end
