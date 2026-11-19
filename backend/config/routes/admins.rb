devise_for :admins, path: "admins", only: :sessions, controllers: { sessions: "admins/sessions" }

namespace :admins do
  root "dashboard#index"
  resource :account, only: %i[edit update]
  resources :apps
  resources :administrators, only: %i[index new create edit update]
  resource :personal_appearance, only: %i[update destroy], controller: "personal_appearance"
  namespace :system_settings do
    resource :storage, only: %i[edit update], controller: "storage"
    resource :appearance, only: %i[edit update], controller: "appearance"
  end
  # 兼容旧存储页的书签和已打开的表单。
  resource :system_settings, only: %i[edit update], controller: "system_settings/storage"
  resources :operation_logs, only: %i[index show]
  resources :reservations, only: %i[index show edit]
  resources :customers, only: :index
  resources :components, only: :index
end
