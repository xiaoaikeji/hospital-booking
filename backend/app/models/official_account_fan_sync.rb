class OfficialAccountFanSync < ApplicationRecord
  belongs_to :app
  belongs_to :operator, class_name: "Admin"
  scope :active, -> { where(state: %w[queued running]) }

  def busy?
    state.in?(%w[queued running]) && updated_at > 1.hour.ago
  end
end
