# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # "For this profile" (PROPOSAL §7.4): which profiles a movie, show,
    # channel or album is tagged for. Admins only.
    class ProfileTagsController < BaseController
      before_action :require_admin!

      # ?taggable_type=&taggable_id= → the profiles it's tagged for.
      sig { void }
      def index
        render json: { profile_ids: ProfileTag.where(profile_id: Profile.select(:id), taggable: taggable).pluck(:profile_id) }
      end

      # { profile_id, taggable_type, taggable_id, tagged }
      sig { void }
      def update
        profile = Profile.find(params.require(:profile_id))
        if bool_param(:tagged)
          ProfileTag.find_or_create_by!(profile: profile, taggable: taggable)
        else
          ProfileTag.where(profile: profile, taggable: taggable).delete_all
        end
        index
      end

      private

      sig { returns(T.any(Movie, Show, Channel, Album)) }
      def taggable
        id = params.require(:taggable_id).to_s
        case params.require(:taggable_type).to_s
        when "movie" then Movie.find(id)
        when "show" then Show.find(id)
        when "channel" then Channel.find(id)
        when "album" then Album.find(id)
        else raise ActiveRecord::RecordNotFound
        end
      end
    end
  end
end
