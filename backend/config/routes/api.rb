namespace :api do
  post "wechat/pay/:version/:config_ref/:kind", to: "wechat_payment_notifications#create", as: :wechat_payment_notification,
    constraints: { version: /v[23]/, config_ref: /[a-f0-9]{64}/, kind: /payment|refund/ }, format: false
  get "wechat/official_accounts/:appid/messages", to: "wechat_official_account_messages#verify", as: :wechat_official_account_messages
  post "wechat/official_accounts/:appid/messages", to: "wechat_official_account_messages#create"
  get "apps/:provider/:appid/configuration", to: "app_configurations#show", as: :app_configuration
  get "apps/:provider/:appid/configuration/images/:id/:key", to: "app_configurations#image",
    as: :app_configuration_image, constraints: { id: /\d+/, key: /[\w.]+/ }, format: false
  get "avatars/:signed_id", to: "user_avatars#show", as: :user_avatar, format: false

  scope "apps/wechat/:appid", module: :mini_program, as: :mini_program do
    resource :session, only: %i[create destroy]
    resource :me, only: %i[show update], controller: :profiles
    resource :phone_binding, only: :create
    resources :entry_scenes, only: :create
  end
end
