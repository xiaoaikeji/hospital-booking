namespace :settings do
  desc "在本机加密 credentials 中补齐配置加密主密钥，不输出密钥值"
  task encryption_keys: :environment do
    credentials = Rails.application.credentials
    values = credentials.config.deep_dup
    keys = values[:active_record_encryption] ||= {}
    %i[primary_key deterministic_key key_derivation_salt].each { |key| keys[key] ||= SecureRandom.hex(32) }
    credentials.write(values.to_yaml)
    puts "加密主密钥已就绪；请独立保管 credentials 和解密主密钥"
  end
end
