devise_for :admins, path: "admins", only: :sessions, controllers: { sessions: "admins/sessions" }

namespace :admins do
  root "dashboard#index"
  resources :posters, only: %i[index new create edit update destroy] do
    get :background, on: :member
  end
  resource :poster_code, only: :create
  resource :background_jobs, only: :show
  resource :account, only: %i[edit update]
  resources :plugins, only: :index
  resource :user_sharing, only: %i[edit update], controller: "user_sharing"
  resources :notifications, only: %i[index show] do
    post :retry_failed, on: :member
  end
  resources :template_messages, only: :index
  resources :reply_contents, only: :index
  resources :wechat_notifications, only: :index
  resources :official_account_menus, only: :index
  resources :official_account_fans, only: :index
  resources :channel_qrcodes, only: :index
  resources :page_links, only: %i[index new create edit update destroy] do
    patch :status, on: :member
    get :image, on: :member
  end
  resources :departments, only: %i[index show new create edit update] do
    patch :status, on: :member
    get :image, on: :member
  end
  resources :doctors, only: %i[index show new create edit update destroy] do
    post :export_schedule, on: :collection
    patch :status, on: :member
    get :image, on: :member
    resource :schedule, only: :show, controller: :doctor_schedules do
      get :clock
      patch :weekly, action: :update_weekly
      patch :date_adjustment, action: :update_date_adjustment
      delete :date_adjustment, action: :revoke_date_adjustment, as: :revoke_date_adjustment
    end
  end
  resources :apps do
    patch :disable, on: :member
    resource :template_message, only: %i[update destroy], controller: "template_messages"
    resources :reply_contents, only: %i[new create edit update] do
      post :media, on: :collection
      get :image, on: :collection
    end
    resource :reply_rules, only: %i[edit update]

    resources :channel_qrcodes, only: %i[new create show edit update]
    resources :fans, controller: "official_account_fans", only: :show do
      post :sync, on: :collection
    end
    resource :official_account_menu, only: [], controller: "official_account_menus" do
      post :publish
      post :pull
      post :media
      get :articles
      get :image
    end
    resources :plugins, only: %i[create update destroy], controller: "app_plugins" do
      post :verify, on: :member
    end
    resource :qrcode, only: :show, controller: "wechat_qrcodes" do
      post :refresh
    end
  end
  resources :administrators, only: %i[index new create edit update]
  resource :personal_appearance, only: %i[update destroy], controller: "personal_appearance"
  namespace :system_settings do
    resource :hospital, only: %i[edit update], controller: "hospital" do
      get :image
    end
    resource :appointment, only: %i[edit update], controller: "appointment"
    resource :wechat_pay, only: %i[edit update], controller: "wechat_pay"
    resource :map, only: %i[edit update], controller: "map"
    resource :storage, only: %i[edit update], controller: "storage"
    resource :wecom_notifications, only: %i[edit update], controller: "wecom_notifications"
    resource :appearance, only: %i[edit update], controller: "appearance"
  end
  # 兼容旧存储页的书签和已打开的表单。
  resource :system_settings, only: %i[edit update], controller: "system_settings/storage"
  resources :operation_logs, only: %i[index show]
  resources :reservations, only: %i[index show], param: :order_no, constraints: { order_no: /[0-9]{20}/ } do
    member do
      patch :complete
      post :return_booking
      post :refund_difference
      patch "refunds/:refund_record_id", action: :review_refund, as: :review_refund
      post "refunds/:refund_record_id/sync", action: :sync_refund, as: :sync_refund
    end
  end
  resources :reservation_previews, path: "components/reservations", only: %i[index show edit]
  resources :customers, only: %i[index show]
  resources :components, only: :index
end
