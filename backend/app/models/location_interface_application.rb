class LocationInterfaceApplication < ApplicationRecord
  belongs_to :app
  belongs_to :operator, class_name: "Admin"
  has_many_attached :pictures
end
