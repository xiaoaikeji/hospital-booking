namespace :api do
  get "apps/:provider/:appid/configuration", to: "app_configurations#show", as: :app_configuration
end
