Ao3Backup::Engine.routes.draw do
  root to: "imports#index"
  resources :import_sessions, controller: "imports", only: [:create, :show, :update, :destroy] do
    member do
      get :confirm_delete
      post :cancel
      post :retry_fetch
      post :recover_dispatch
    end
  end
end
