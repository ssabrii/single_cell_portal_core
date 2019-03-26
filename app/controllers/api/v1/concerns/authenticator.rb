module Api
  module V1
    module Concerns
      module Authenticator
        extend ActiveSupport::Concern
        include CurrentApiUser

        included do
          before_action :authenticate_api_user!, unless: proc { %w(schemas taxons status site).include?(controller_name)}
        end

        def authenticate_api_user!
          head 401 unless api_user_signed_in?
        end

        def api_user_signed_in?
          current_api_user.present?
        end

      end
    end
  end
end

