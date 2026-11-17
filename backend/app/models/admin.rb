class Admin < ApplicationRecord
  ROLES = { "super_admin" => "超级管理员", "operator" => "运营管理员", "customer_service" => "客服" }.freeze
  DEFAULT_PASSWORD = "123456".freeze
  devise :database_authenticatable, :rememberable, :trackable
  normalizes :username, with: ->(value) { value.to_s.strip.downcase }
  before_validation(on: :create) { self.password = DEFAULT_PASSWORD if password.blank? }
  validates :username, presence: true, uniqueness: true, length: { maximum: 100 }, format: { with: /\A[a-z0-9_]+\z/, message: "只能包含字母、数字和下划线" }
  validates :name, length: { maximum: 100 }
  validates :role, inclusion: { in: ROLES.keys }
  validates :enabled, inclusion: { in: [ true, false ] }
  validates :password, length: { in: 6..128 }, confirmation: true, allow_blank: true
  validate :retain_enabled_super_admin, on: :update

  def super_admin? = role == "super_admin"
  def display_name = name.presence || username
  def role_name = ROLES.fetch(role)
  def active_for_authentication? = super && enabled?

  # 锁住启用超管后再刷新目标账号，防止并发停用或降级导致没有可用超管。
  def self.update_managed(record, attributes, actor:, request: nil)
    transaction do
      where(role: "super_admin", enabled: true).order(:id).lock.load
      record.reload
      record.assign_attributes(attributes)
      if record.save
        fields = record.saved_changes.keys - %w[updated_at encrypted_password]
        fields << "password" if record.saved_change_to_encrypted_password?
        Log.record!(action: "admin.update", category: "security", actor: actor, target: record,
          details: { "fields" => fields }, request: request)
        true
      else
        false
      end
    end
  end

  private

  def retain_enabled_super_admin
    return unless role_in_database == "super_admin" && enabled_in_database && (!super_admin? || !enabled?)
    if self.class.where(role: "super_admin", enabled: true).where.not(id: id).none?
      errors.add(:base, "至少保留一个启用的超级管理员")
    end
  end
end
