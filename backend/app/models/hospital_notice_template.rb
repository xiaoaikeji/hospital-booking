class HospitalNoticeTemplate < ApplicationRecord
  attr_readonly :event
  self.filter_attributes += [:messages]
  validates :event, inclusion: { in: Appointments::GroupNotice::EVENTS.keys }
  validates :name, presence: true, length: { maximum: 80 }

  def revision = Digest::SHA256.hexdigest([name, messages].to_json)

  def change_enabled!(value)
    transaction do
      self.class.connection.execute("SELECT pg_advisory_xact_lock(71020013)")
      reload
      next if enabled == value

      siblings = self.class.where(event: event)
      if value
        # Keep the event generation across switches, including a later reactivation.
        latest = siblings.maximum(:generation)
        siblings.where(enabled: true).update_all(enabled: false, updated_at: Time.current)
        update!(enabled: true, generation: latest)
      else
        update!(enabled: false, generation: generation + 1)
      end
      yield if block_given?
    end
  end
end
