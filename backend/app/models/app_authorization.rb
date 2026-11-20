class AppAuthorization < ApplicationRecord
  belongs_to :app
  belongs_to :initiator, class_name: "Admin", optional: true
  encrypts :refresh_token
  def authorized? = refresh_token.present?

  def used?
    [authorized_at, revoked_at, event_at, original_id, scopes, refresh_token_before_type_cast].any?(&:present?)
  end
end
