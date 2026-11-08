# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Settings › Import from Plex (PROPOSAL §7.4): the server, who is who, and
    # whether to keep syncing. Admins only; the token is write-only.
    class PlexConnectionsController < BaseController
      before_action :require_admin!

      sig { void }
      def show
        render json: PlexSerializer.connection_json(PlexConnection.find_by(household_id: current_household!.id))
      end

      sig { void }
      def update
        attrs = params.require(:plex_connection).permit(:server_url, :token, :sync_enabled)
        connection = PlexConnection.find_or_initialize_by(household_id: current_household!.id)
        connection.server_url = attrs[:server_url].to_s if attrs.key?(:server_url)
        connection.token = attrs[:token].to_s.strip if attrs[:token].present?
        connection.sync_enabled = ActiveModel::Type::Boolean.new.cast(attrs[:sync_enabled]) ? true : false if attrs.key?(:sync_enabled)
        connection.save!
        render json: PlexSerializer.connection_json(connection)
      end

      sig { void }
      def destroy
        PlexConnection.find_by(household_id: current_household!.id)&.destroy!
        head :no_content
      end

      # Checks the server and refreshes who's in the Plex Home.
      sig { void }
      def test
        connection = PlexConnection.find_by(household_id: current_household!.id)
        return render json: { ok: false, message: "Save the Plex server first." } if connection.nil?

        ok, message = Plex::ConnectionCheck.new(connection).call
        render json: { ok: ok, message: message }
      end

      # Points one Plex user at a profile: an existing one, a new one named
      # after them ("new"), or nobody (blank).
      sig { void }
      def map_user
        connection = PlexConnection.find_by!(household_id: current_household!.id)
        mapping = connection.plex_user_mappings.find(params.require(:mapping_id))
        target = params[:profile_id].to_s
        profile =
          case target
          when "" then nil
          when "new" then Profile.create!(name: unique_profile_name(mapping.plex_name))
          else Profile.find(target)
          end
        mapping.update!(profile: profile)
        render json: PlexSerializer.connection_json(connection.reload)
      end

      private

      sig { params(name: String).returns(String) }
      def unique_profile_name(name)
        taken = Profile.pluck(:name).to_set
        candidate = name.truncate(40)
        suffix = 2
        while taken.include?(candidate)
          candidate = "#{name.truncate(36)} #{suffix}"
          suffix += 1
        end
        candidate
      end
    end
  end
end
