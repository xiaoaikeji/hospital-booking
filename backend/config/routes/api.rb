namespace :api do
  post "wechat/component/events", to: "wechat_events#create"
  post "wechat/component/apps/:appid/messages", to: "wechat_events#create"
  get "wechat/component/authorization/callback", to: "/admins/wechat_authorizations#callback", as: :wechat_authorization_callback
  get "apps/:provider/:appid/configuration", to: "app_configurations#show", as: :app_configuration
end
