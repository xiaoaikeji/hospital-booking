class UserIpLocationWorker
  include Sidekiq::Job
  sidekiq_options retry: 2

  def perform(user_id = nil)
    settings = MapSettings.new
    return if settings.key.blank?
    revision = settings.lookup_revision
    pending = User.where("login_profile ? 'first_ip' AND NOT (login_profile ? 'region')")
    return dispatch(pending, revision) unless user_id

    User.transaction do
      # Workers for a replacement provider need not wait for an old HTTP request.
      lock = Digest::SHA256.digest("booking.ip_location.#{revision}.#{user_id}").unpack1("q>")
      next unless User.connection.select_value("SELECT pg_try_advisory_xact_lock(#{lock})")
      user = pending.find_by(id: user_id)
      next unless user
      ip = user.login_profile.fetch("first_ip")
      region = IpLocation.lookup(ip, settings: settings)
      next if region.blank?
      next unless MapSettings.current_for_lookup?(revision)
      user.with_lock do
        if user.login_profile["first_ip"] == ip && !user.login_profile.key?("region")
          user.update!(login_profile: user.login_profile.merge("region" => region))
        end
      end
    end
  end

  private

  # The committed profile is the pending work. Web requests never wait for Redis or the map service.
  def dispatch(pending, revision)
    pending.in_batches(of: 200) do |batch|
      ids = batch.pluck(:id).reject { |id| Rails.cache.exist?("ip_location/#{revision}/#{id}") }
      next if ids.empty?
      self.class.perform_bulk(ids.map { |id| [ id ] })
      # A failed enqueue leaves the rows eligible on the next pass.
      ids.each { |id| Rails.cache.write("ip_location/#{revision}/#{id}", true, expires_in: 30.minutes) }
    end
  end
end
