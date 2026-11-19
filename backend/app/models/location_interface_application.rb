class LocationInterfaceApplication < ApplicationRecord
  belongs_to :app
  belongs_to :operator, class_name: "Admin"
  has_many_attached :pictures

  def uncertain? = state == "unconfirmed"

  def awaiting_list?(review)
    state == "accepted" && previous_review == review
  end
end
