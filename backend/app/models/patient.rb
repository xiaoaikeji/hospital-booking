class Patient < ApplicationRecord
  PROFILE_FIELDS = %w[name gender age].freeze

  belongs_to :user
  attr_readonly :user_id

  normalizes :name, with: ->(name) { name.strip }
  validates :name, presence: true, length: { maximum: 100 }
  validates :gender, numericality: { only_integer: true, in: 0..2 }
  validates :age, numericality: { only_integer: true, in: 1..200 }

  def record_change!(action, request: nil, status: "success", details: {})
    Log.record!(category: "booking", action: "patient.#{action}", source: "user", actor: user, target: self,
      request: request, status: status, details: details)
  end
end
