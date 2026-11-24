namespace :admin do
  desc "创建首个超级管理员（生产环境必须显式设置非默认密码），不覆盖已有账号"
  task create: :environment do
    Admins::InitialCreator.new.call
  rescue Admins::InitialCreator::Error => e
    abort e.message
  end
end
