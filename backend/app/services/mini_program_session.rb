# The row ID locates the binding. Each device proves possession of its own random secret.
class MiniProgramSession
  TTL = 30.days
  FORMAT = /\A([1-9]\d{0,18})\.[A-Za-z0-9_-]{43}\z/

  def self.issue!(identity)
    identity.with_lock do
      now = Time.current
      token = "#{identity.id}.#{SecureRandom.urlsafe_base64(32)}"
      expires_at = (now + TTL).change(usec: 0)
      digest = Digest::SHA256.hexdigest(token)
      live = identity.sessions.select { |_digest, expiry| expiry > now.to_i }
      identity.update!(sessions: live.merge(digest => expires_at.to_i))
      receipt = logout_verifier.generate([ identity.id, digest ], expires_at: expires_at)
      { token: token, expires_at: expires_at, logout_token: "logout.#{receipt}" }
    end
  end

  def initialize(app, token)
    match = FORMAT.match(token.to_s)
    @bindings = UserApp.for_app(app)
    @id = match[1].to_i if match && match[1].to_i <= 2**63 - 1
    @digest = Digest::SHA256.hexdigest(token) if @id
    @logout_receipt = token.delete_prefix("logout.") if token&.start_with?("logout.")
  end

  def self.logout_verifier = Rails.application.message_verifier("mini_program_session_logout")

  def self.prune_expired!
    cutoff = Time.current.to_i
    expired = UserApp.where("jsonb_path_exists(sessions, '$.* ? (@ <= $cutoff)', jsonb_build_object('cutoff', :time::bigint))", time: cutoff)
    expired.select(:id).find_each do |identity|
      identity.with_lock do
        live = identity.sessions.select { |_digest, expiry| expiry > cutoff }
        identity.update!(sessions: live) if live.size != identity.sessions.size
      end
    end
  end

  def identity(lock: false)
    return unless @id
    binding = @bindings.lock(lock).find_by(id: @id)
    binding if binding && binding.sessions.fetch(@digest, 0) > Time.current.to_i
  end

  def revoke!
    # Only DELETE accepts a logout receipt. An offline guest can surrender it without retaining access to the profile.
    id, digest = @logout_receipt ? self.class.logout_verifier.verified(@logout_receipt) : [ @id, @digest ]
    return unless id
    UserApp.transaction do
      binding = @bindings.lock.find_by(id: id)
      next unless binding&.sessions&.key?(digest)
      now = Time.current.to_i
      binding.update!(sessions: binding.sessions.reject { |stored, expiry| stored == digest || expiry <= now })
    end
  end
end
