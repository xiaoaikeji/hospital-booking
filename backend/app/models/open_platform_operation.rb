class OpenPlatformOperation < ApplicationRecord
  belongs_to :app
  belongs_to :open_platform_account, optional: true
end
