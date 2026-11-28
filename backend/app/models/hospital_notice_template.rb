class HospitalNoticeTemplate < ApplicationRecord
  attr_readonly :event
  self.filter_attributes += [:messages]
  validates :event, inclusion: { in: Appointments::GroupNotice::EVENTS.keys }
  validates :name, presence: true, length: { maximum: 80 }

  def revision = Digest::SHA256.hexdigest([name, messages].to_json)

  def change_enabled!(value)
    committed = transaction(requires_new: true) do
      self.class.connection.execute("SELECT pg_advisory_xact_lock(71020013)")
      reload
      next true if enabled == value

      siblings = self.class.where(event: event)
      saved = if value
        # Keep the event generation across switches, including a later reactivation.
        latest = siblings.maximum(:generation)
        siblings.where(enabled: true).update_all(enabled: false, updated_at: Time.current)
        update!(enabled: true, generation: latest)
      else
        update!(enabled: false, generation: generation + 1)
      end
      raise ActiveRecord::RecordNotSaved unless saved
      yield if block_given?
      true
    end
    raise ActiveRecord::RecordNotSaved unless committed
  end
end
