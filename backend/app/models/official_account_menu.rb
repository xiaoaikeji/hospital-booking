class OfficialAccountMenu < ApplicationRecord
  belongs_to :app

  before_destroy do
    if buttons.present? || !pending_buttons.nil?
      errors.add(:base, "请先核实并清空公众号菜单")
      throw :abort
    end
  end
end
