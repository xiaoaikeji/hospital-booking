module Admins::CustomersHelper
  def customer_usage(identities)
    logged_in = identities.any? do |identity|
      identity.app_type == "mini_program" && (identity.sign_in_count.positive? || identity.last_sign_in_at?)
    end
    return "已登录小程序" if logged_in
    return "仅公众号记录" if identities.any? { |identity| identity.app_type == "official_account" }
    "尚未登录小程序"
  end

  def customer_status_badge(status)
    color = status == "active" ? "success" : "secondary"
    tag.span(Admins::CustomersController::STATUSES.fetch(status), class: "badge bg-#{color}-lt")
  end
end
