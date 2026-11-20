class WechatPluginUpdate < ApplicationRecord
  belongs_to :app

  def conflicts_with_list?(listed_version)
    confirmed? && listed_version.present? && listed_version != version
  end
end
