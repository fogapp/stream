# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # The web sidebar as this profile arranged it: the order of its items and
    # the ones it hid. Keys are the client's (`live`, `library:<id>`); one
    # that no longer names anything is simply never shown.
    class SidebarController < BaseController
      KEY = T.let(/\A[a-z_]+(:[0-9a-f-]{36})?\z/, Regexp)

      sig { void }
      def show
        render json: SidebarSerializer.json(current_profile!)
      end

      # { order: [keys], hidden: [keys] }
      sig { void }
      def update
        keys = ->(name) { Array(params[name]).map(&:to_s).grep(KEY).uniq.first(100) }
        current_profile!.update!(sidebar: { "order" => keys.call(:order), "hidden" => keys.call(:hidden) })
        show
      end
    end
  end
end
