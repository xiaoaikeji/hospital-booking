namespace :admin do
  desc "创建首个超级管理员（默认用户名 admin、密码 123456），不覆盖已有账号"
  task create: :environment do
    abort "管理员已存在，请在后台管理账号" if Admin.exists?
    Admin.transaction do
      admin = Admin.create!(username: ENV.fetch("ADMIN_USERNAME", "admin"), password: ENV.fetch("ADMIN_PASSWORD", Admin::DEFAULT_PASSWORD), role: "super_admin", name: "超级管理员")
      Log.record!(action: "admin.create", category: "security", actor: admin, target: admin, source: "console")
      puts "已创建超级管理员：#{admin.username}"
    end
  end
end
