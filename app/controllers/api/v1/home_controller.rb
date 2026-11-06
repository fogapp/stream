# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # The home screen (PROPOSAL §7.1), and the profile's arrangement of it.
    class HomeController < BaseController
      sig { void }
      def show
        render json: Viewing::Home.new(current_profile!).call
      end

      # { order: [hub keys], hidden: [hub keys] }
      sig { void }
      def update
        keys = ->(name) { Array(params[name]).map(&:to_s).grep(/\A[a-z_]+(:[0-9a-f-]{36})?\z/).uniq.first(100) }
        current_profile!.update!(home_layout: current_profile!.home_layout.merge("order" => keys.call(:order), "hidden" => keys.call(:hidden)))
        show
      end

      # Pin a collection or one of this profile's playlists to Home as a row
      # of its own (PROPOSAL §7.1); DELETE unpins it.
      sig { void }
      def pin
        kind = params.require(:kind).to_s
        id = params.require(:id).to_s
        found = kind == "collection" ? Collection.find_by(id: id) : kind == "playlist" ? Playlist.find_by(id: id, profile: current_profile!) : nil
        raise ActiveRecord::RecordNotFound if found.nil?

        layout = current_profile!.home_layout
        pins = Array(layout["pinned"]).reject { |pinned| pinned["kind"] == kind && pinned["id"] == id }
        pins << { "kind" => kind, "id" => id } if request.post?
        current_profile!.update!(home_layout: layout.merge("pinned" => pins.first(20)))
        render json: { pinned: request.post? }
      end
    end
  end
end
