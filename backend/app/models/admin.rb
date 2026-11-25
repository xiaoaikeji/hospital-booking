class Admin < ApplicationRecord
  ROLES = { "super_admin" => "超级管理员", "operator" => "运营管理员", "customer_service" => "客服" }.freeze
  DEFAULT_PASSWORD = "123456".freeze
  BLANK_PASSWORD_PATTERN = /\A[[:space:]\u180E\u200B-\u200D\u2060\uFEFF]*\z/
  EDGE_WHITESPACE_PATTERN = /\A[[:space:]\u180E\u200B-\u200D\u2060\uFEFF]+|[[:space:]\u180E\u200B-\u200D\u2060\uFEFF]+\z/

  attr_accessor :require_explicit_password

  def self.blank_password?(value)
    return true if value.nil?

    text = value.to_s
    text.blank? || (text.valid_encoding? && text.match?(BLANK_PASSWORD_PATTERN))
  end

  def self.default_password?(value)
    text = value.to_s
    return true if text == DEFAULT_PASSWORD
    return false unless text.valid_encoding?

    text.gsub(EDGE_WHITESPACE_PATTERN, "") == DEFAULT_PASSWORD
  end

  devise :database_authenticatable, :rememberable, :trackable
  normalizes :username, with: ->(value) { value.to_s.strip.downcase }
  before_validation(on: :create) do
    self.password = DEFAULT_PASSWORD if self.class.blank_password?(password) && !explicit_password_required?
  end
  validates :username, presence: true, uniqueness: true, length: { maximum: 100 }, format: { with: /\A[a-z0-9_]+\z/, message: "只能包含字母、数字和下划线" }
  validates :name, length: { maximum: 100 }
  validates :role, inclusion: { in: ROLES.keys }
  validates :enabled, inclusion: { in: [ true, false ] }
  validates :password, length: { in: 6..128 }, confirmation: true, allow_blank: true
  validate :ensure_explicit_password, on: :create, if: :explicit_password_required?
  validate :ensure_secure_super_admin_update, on: :update, if: :production_super_admin?
  validate :retain_enabled_super_admin, on: :update

  def super_admin? = role == "super_admin"
  def maintain_booking_directory? = super_admin? || role == "operator"
  def display_name = name.presence || username
  def role_name = ROLES.fetch(role)
  def active_for_authentication? = super && enabled?

  # 锁住启用超管后再刷新目标账号，防止并发停用或降级导致没有可用超管。
  def self.update_managed(record, attributes, actor:, request: nil)
    record.with_operation_log("admin.update", actor: actor, request: request) do
      where(role: "super_admin", enabled: true).order(:id).lock.load
      record.reload.update(attributes)
    end
  end

  def with_operation_log(action, actor:, request:)
    audit = { action: action, category: "security", actor: actor, target: self, request: request }
    reason = "账号校验失败"
    begin
      saved = self.class.transaction(requires_new: true) do
        raise ActiveRecord::Rollback unless yield

        fields = saved_changes.keys & %w[username name role enabled]
        fields << "password" if saved_change_to_encrypted_password?
        Log.record!(**audit, details: { fields: fields })
        true
      end
    rescue ActiveRecord::ActiveRecordError
      reason = "数据库写入失败"
      errors.add(:base, "未保存，#{reason}")
    end
    return true if saved

    Log.record!(**audit, status: "failed", details: { reason: reason })
    false
  end

  private

  def production_super_admin?
    Rails.env.production? && super_admin?
  end

  def explicit_password_required?
    require_explicit_password || production_super_admin? ||
      (Rails.env.production? && password.is_a?(String) && self.class.blank_password?(password))
  end

  def ensure_explicit_password
    if self.class.blank_password?(password)
      errors.add(:password, "不能为空或全空白")
    elsif self.class.default_password?(password)
      errors.add(:password, "不能使用公开默认密码")
    end
  end

  def ensure_secure_super_admin_update
    if will_save_change_to_encrypted_password?
      ensure_explicit_password
    elsif will_save_change_to_role? && valid_password?(DEFAULT_PASSWORD)
      errors.add(:password, "设为超级管理员时须更换公开默认密码")
    end
  end

  def retain_enabled_super_admin
    return unless role_in_database == "super_admin" && enabled_in_database && (!super_admin? || !enabled?)
    if self.class.where(role: "super_admin", enabled: true).where.not(id: id).none?
      errors.add(:base, "至少保留一个启用的超级管理员")
    end
  end
end
