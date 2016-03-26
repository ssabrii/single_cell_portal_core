Rails.application.routes.draw do
  devise_for :users, :controllers => { :omniauth_callbacks => 'users/omniauth_callbacks' }
  resources :studies
  get 'study/:study_name', to: 'site#study', as: :view_study
  get 'render_cluster/:study_name', to: 'site#render_cluster', as: :render_cluster
  post 'study/:study_name/search', to: 'site#search_genes', as: :search_genes
  get 'study/:study_name/gene_expression/:gene/', to: 'site#view_gene_expression', as: :view_gene_expression
  get 'study/:study_name/render_gene_expression_plots/:gene/', to: 'site#render_gene_expression_plots', as: :render_gene_expression_plots
  get 'study/:study_name/gene_expression', to: 'site#view_gene_expression_heatmap', as: :view_gene_expression_heatmap
  get 'study/:study_name/all_gene_expression', to: 'site#view_all_gene_expression_heatmap', as: :view_all_gene_expression_heatmap
  get 'study/:study_name/load_heatmap_as_gct', to: 'site#load_heatmap_as_gct', as: :load_heatmap_as_gct
  get 'render_heatmap/:study_name', to: 'site#render_heatmap', as: :render_heatmap
  get '/', to: 'site#index', as: :site
  root to: 'site#index'

  # The priority is based upon order of creation: first created -> highest priority.
  # See how all your routes lay out with "rake routes".

  # You can have the root of your site routed with "root"
  # root 'welcome#index'

  # Example of regular route:
  #   get 'products/:id' => 'catalog#view'

  # Example of named route that can be invoked with purchase_url(id: product.id)
  #   get 'products/:id/purchase' => 'catalog#purchase', as: :purchase

  # Example resource route (maps HTTP verbs to controller actions automatically):
  #   resources :products

  # Example resource route with options:
  #   resources :products do
  #     member do
  #       get 'short'
  #       post 'toggle'
  #     end
  #
  #     collection do
  #       get 'sold'
  #     end
  #   end

  # Example resource route with sub-resources:
  #   resources :products do
  #     resources :comments, :sales
  #     resource :seller
  #   end

  # Example resource route with more complex sub-resources:
  #   resources :products do
  #     resources :comments
  #     resources :sales do
  #       get 'recent', on: :collection
  #     end
  #   end

  # Example resource route with concerns:
  #   concern :toggleable do
  #     post 'toggle'
  #   end
  #   resources :posts, concerns: :toggleable
  #   resources :photos, concerns: :toggleable

  # Example resource route within a namespace:
  #   namespace :admin do
  #     # Directs /admin/products/* to Admin::ProductsController
  #     # (app/controllers/admin/products_controller.rb)
  #     resources :products
  #   end
end
