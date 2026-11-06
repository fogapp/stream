# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Asking Hook for films and television from the palette (PROPOSAL §7.9):
    # search beyond Stream, want a film, add a show and want its seasons,
    # follow it. Hook is connected by fog (Hook::Client), and every call asks
    # as the person signed in. Guests and kid profiles watch; they don't ask.
    class HookRequestsController < BaseController
      before_action :require_asker!, except: %i[show test]
      before_action :require_admin!, only: :test

      rescue_from UpstreamHttpClient::Error, with: :render_hook_error

      # Whether the palette offers Hook to this person at all.
      sig { void }
      def show
        render json: { available: asker? }
      end

      sig { void }
      def search
        kind = Hook::Requests::Kind.try_deserialize(params[:kind].to_s)
        return render_errors("Search for a movie or a show") if kind.nil?

        query = params[:q].to_s.strip
        return render json: [] if query.length < 2

        render json: Hook::Requests.search(client, kind: kind, query: query)
      end

      sig { void }
      def movie
        want = Hook::Requests.want_movie(client, provider: params.require(:provider).to_s,
          external_id: params.require(:external_id).to_s)
        render json: { status: want["status"], explain: want["explain"] }, status: :created
      end

      # POST: Hook adds the show to its own catalog when it hasn't it yet.
      sig { void }
      def show_seasons
        render json: Hook::Requests.show(client, provider: params.require(:provider).to_s,
          external_id: params.require(:external_id).to_s)
      end

      sig { void }
      def want_show
        follow = Hook::Requests::Follow.try_deserialize(params[:follow].to_s)
        return render_errors("Follow for new episodes or for everything") if params[:follow].present? && follow.nil?

        seasons = Array(params[:season_numbers]).filter_map { |number| Integer(number.to_s, exception: false) }
        return render_errors("Choose a season or follow the show") if seasons.empty? && follow.nil?

        render json: Hook::Requests.want_show(client, show_id: params.require(:id).to_s, season_numbers: seasons,
          follow: follow), status: :created
      end

      # Settings › Integrations: Hook answers, and who it takes the asker to be.
      sig { void }
      def test
        return render json: { ok: false, message: not_connected } unless Hook::Client.configured?

        ok, message = client.test_connection
        render json: { ok: ok, message: message }
      end

      private

      sig { returns(T::Boolean) }
      def asker?
        profile = Current.profile
        Hook::Client.configured? && !current_user!.guest? && !(profile.is_a?(Profile) && profile.kid?)
      end

      sig { void }
      def require_asker!
        return if asker?

        message = Hook::Client.configured? ? "Only a grown-up in the household asks Hook for things" : not_connected
        render_errors(message, status: :forbidden)
      end

      sig { returns(String) }
      def not_connected = "Hook isn't connected — connect Hook's Library offer on Stream's Integrations tab in fog"

      sig { returns(Hook::Client) }
      def client = Hook::Client.new(on_behalf_of: current_user!.email)

      # Hook's own sentence when it gave one ("already has this version"): a
      # refusal is the person's to read, 422; a Hook that didn't answer, 502.
      sig { params(error: UpstreamHttpClient::Error).void }
      def render_hook_error(error)
        refused = error.status.to_i.between?(400, 499)
        render_errors(error.detail.presence || error.message, status: refused ? :unprocessable_content : :bad_gateway)
      end
    end
  end
end
