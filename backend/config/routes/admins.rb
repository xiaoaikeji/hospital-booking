devise_for :admins, path: "admins", only: :sessions, controllers: { sessions: "admins/sessions" }

namespace :admins do
  root "dashboard#index"
  resource :account, only: %i[edit update]
  resources :administrators, only: %i[index new create edit update]
  resource :system_settings, only: %i[edit update], controller: "system_settings"
  resources :operation_logs, only: %i[index show]
  resources :reservations, only: %i[index show edit]
  resources :customers, only: :index
  resources :components, only: :index
end
