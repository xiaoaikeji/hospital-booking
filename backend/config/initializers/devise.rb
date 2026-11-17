require "devise/orm/active_record"

Devise.setup do |config|
  config.authentication_keys = [ :username ]
  config.case_insensitive_keys = [ :username ]
  config.strip_whitespace_keys = [ :username ]
  config.password_length = 6..128
  config.stretches = Rails.env.test? ? 1 : 12
  config.sign_out_via = :delete
  config.scoped_views = true
  config.responder.error_status = :unprocessable_content
  config.responder.redirect_status = :see_other
end

# Devise 拦截的失败（包括已停用会话）也记录；不读取或保存用户名、密码参数。
Warden::Manager.before_failure do |env, options|
  if options[:scope] == :admin && env["REQUEST_METHOD"] == "POST" && options[:attempted_path].to_s.split("?").first == "/admins/sign_in"
    Log.record!(action: "admin.sign_in", category: "security", status: "failed", request: ActionDispatch::Request.new(env))
  end
end
