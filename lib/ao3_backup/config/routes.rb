Ao3Backup::Engine.routes.draw do
  root to: "imports#index"
  resources :import_sessions, controller: "imports", only: [:create, :show, :update] do
    member do
      post :cancel
      post :retry_fetch
      post :recover_dispatch
    end
  end
end
