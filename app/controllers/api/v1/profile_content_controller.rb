# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # One profile's own corner of the catalog (Settings › Profiles): the
    # movies, shows and channels hidden from it (Viewing::Access leaves them
    # out everywhere) and, for admins, what's tagged for it. An admin manages
    # any profile; a profile manages its own list, unless it's a kid's.
    class ProfileContentController < BaseController
      finds :profile, from: -> { Profile.all }, param: :profile_id
      before_action :require_manager!

      sig { void }
      def show
        hidden = ProfileExclusion.where(profile: profile).includes(:excludable).order(created_at: :desc).filter_map(&:excludable)
        body = { hidden: ProfileContentSerializer.items(hidden) }
        if current_user!.admin?
          tagged = ProfileTag.where(profile: profile).includes(:taggable).order(created_at: :desc).filter_map(&:taggable)
          body[:tagged] = ProfileContentSerializer.items(tagged)
        end
        render json: body
      end

      # { kind, id, hidden }. Hiding needs a title this viewer can see;
      # bringing one back needs only the row.
      sig { void }
      def hidden
        kind = params.require(:kind).to_s
        id = params.require(:id).to_s
        if bool_param(:hidden)
          ProfileExclusion.find_or_create_by!(profile: profile, excludable: visible(kind, id))
        else
          ProfileExclusion.where(profile: profile, excludable_type: kind.classify, excludable_id: id).delete_all
        end
        show
      end

      private

      sig { void }
      def require_manager!
        # A kid profile has no settings, whoever signed the browser in.
        return unless require_grown_up!
        return if current_user!.admin? || current_profile! == profile

        render_errors("Only an admin can change another profile", status: :forbidden)
      end

      sig { params(kind: String, id: String).returns(T.any(Movie, Show, Channel)) }
      def visible(kind, id)
        case kind
        when "movie" then Viewing::Access.movies(Movie.where(id: id)).take!
        when "show" then Viewing::Access.shows(Show.where(id: id)).take!
        when "channel" then Viewing::Access.channels(Channel.where(id: id)).take!
        else raise ActiveRecord::RecordNotFound
        end
      end
    end
  end
end
