class OpenPlatformOperation < ApplicationRecord
  belongs_to :app
  belongs_to :open_platform_account, optional: true
  LABELS = { "create" => "新增账号", "bind" => "绑定应用", "unbind" => "解绑应用" }.freeze
end
