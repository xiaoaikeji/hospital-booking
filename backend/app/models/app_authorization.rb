class AppAuthorization < ApplicationRecord
  belongs_to :app
  belongs_to :initiator, class_name: "Admin", optional: true
  encrypts :refresh_token
  def authorized? = refresh_token.present?
end
