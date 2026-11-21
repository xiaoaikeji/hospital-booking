namespace :api do
  get "wechat/official_accounts/:appid/messages", to: "wechat_official_account_messages#verify", as: :wechat_official_account_messages
  post "wechat/official_accounts/:appid/messages", to: "wechat_official_account_messages#create"
  get "apps/:provider/:appid/configuration", to: "app_configurations#show", as: :app_configuration
  get "apps/:provider/:appid/configuration/images/:id/:key", to: "app_configurations#image",
    as: :app_configuration_image, constraints: { id: /\d+/, key: /[\w.]+/ }, format: false
end
