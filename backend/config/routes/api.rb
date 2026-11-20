namespace :api do
  get "wechat/apps/:app_id/location_pictures/:id", to: "location_pictures#show", as: :wechat_location_picture
  post "wechat/component/events", to: "wechat_events#create", as: :wechat_component_events
  post "wechat/component/apps/:appid/messages", to: "wechat_events#create", as: :wechat_component_messages
  get "wechat/component/authorization/callback", to: "/admins/wechat_authorizations#callback", as: :wechat_authorization_callback
  get "apps/:provider/:appid/configuration", to: "app_configurations#show", as: :app_configuration
  get "apps/:provider/:appid/configuration/images/:id/:key", to: "app_configurations#image",
    as: :app_configuration_image, constraints: { id: /\d+/, key: /[\w.]+/ }, format: false
end
