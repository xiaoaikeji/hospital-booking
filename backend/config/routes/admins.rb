devise_for :admins, path: "admins", only: :sessions, controllers: { sessions: "admins/sessions" }

namespace :admins do
  root "dashboard#index"
  resource :account, only: %i[edit update]
  resources :mini_program_releases, only: %i[index show] do
    get :templates, on: :collection
    get :confirmation, on: :member
  end
  resources :code_templates, only: %i[index create destroy]
  resources :apps do
    resources :experiencers, only: :create, controller: "app_experiencers" do
      delete :destroy, on: :collection, path: ""
    end
    resource :privacy_setting, only: %i[edit update], controller: "app_privacy_settings"
    resources :categories, only: %i[create destroy], controller: "app_categories" do
      post :verify, on: :collection
    end
    resource :server_domain, only: :update, controller: "app_domains", defaults: { kind: "server" }
    resource :business_domain, only: :update, controller: "app_domains", defaults: { kind: "business" }
    resource :qrcode, only: :show, controller: "wechat_qrcodes"
    resource :authorization, only: :create, controller: "wechat_authorizations"
    resources :releases, only: %i[new create destroy], controller: "wechat_releases" do
      member do
        get :trial
        post :retry_upload
        patch :verify_upload
        post :submit
        patch :close
      end
    end
    resources :audits, only: [], controller: "wechat_releases" do
      member do
        get "screenshots/:index", action: :screenshot, as: :screenshot, constraints: { index: /\d+/ }
        patch :mode
        patch :sync
        post :resolve
        post :withdraw
        post :resume_auto
        post :publish
      end
    end
  end
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
