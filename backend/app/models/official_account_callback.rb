class OfficialAccountCallback < ApplicationRecord
  belongs_to :app
  attr_readonly :app_id, :digest, :sender_digest, :message
  encrypts :message, :reply_xml
  self.filter_attributes += [ :message, :reply_xml ]

  def fields = JSON.parse(message)
end
