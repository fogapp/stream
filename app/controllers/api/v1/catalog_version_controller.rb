# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Asked every few seconds by an open tab (frontend `useCatalogVersion`),
    # so it is one indexed count and nothing else.
    class CatalogVersionController < BaseController
      sig { void }
      def show
        render json: CatalogVersionSerializer.json(Viewing::Catalog.version(current_household!))
      end
    end
  end
end
