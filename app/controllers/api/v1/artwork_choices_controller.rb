# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Choosing a film's or show's poster or background (PROPOSAL §7.2):
    # TMDB's other pictures, an upload, or back to TMDB's first choice.
    # Admins only, like the rest of metadata editing.
    class ArtworkChoicesController < BaseController
      before_action :require_admin!

      sig { void }
      def index
        client = Tmdb::Client.for(current_household!)
        current = Artwork.ready.find_by(owner: owner, kind: kind.serialize)
        choices =
          if client && owner.tmdb_id
            key = kind == Artwork::Kind::Poster ? "posters" : "backdrops"
            size = kind == Artwork::Kind::Poster ? "w342" : "w780"
            Array(client.images(owner.is_a?(Show) ? "show" : "movie", owner.tmdb_id.to_i)[key]).first(60).map do |image|
              { path: image["file_path"], preview: "https://image.tmdb.org/t/p/#{size}#{image['file_path']}", width: image["width"],
                height: image["height"], language: image["iso_639_1"], votes: image["vote_count"] }
            end
          else
            []
          end
        render json: {
          current: current && ArtworkSerializer.image_json(current).merge(source: current.source_enum, path: current.source_ref),
          locked: owner.locked?("#{kind.serialize}_path"), choices: choices
        }
      rescue UpstreamHttpClient::Error => e
        render_errors("TMDB didn't answer: #{e.message}", status: :bad_gateway)
      end

      sig { void }
      def choose
        Artworks::Choice.choose_tmdb(owner, kind, params.require(:path).to_s)
        render json: { ok: true }
      rescue Artworks::Choice::Error => e
        render_errors(e.message)
      end

      sig { void }
      def upload
        file = params.require(:file)
        return render_errors("Send a picture") unless file.respond_to?(:tempfile)

        Artworks::Choice.upload(owner, kind, file.tempfile.path, size: file.size.to_i)
        render json: { ok: true }, status: :created
      rescue Artworks::Choice::Error => e
        render_errors(e.message)
      end

      sig { void }
      def reset
        Artworks::Choice.reset(owner, kind)
        head :accepted
      end

      private

      sig { returns(T.any(Movie, Show)) }
      def owner
        @owner ||= T.let(
          case params.require(:owner_type).to_s
          when "movie" then Movie.find(params.require(:owner_id))
          when "show" then Show.find(params.require(:owner_id))
          else raise ActiveRecord::RecordNotFound
          end,
          T.nilable(T.any(Movie, Show))
        )
      end

      sig { returns(Artwork::Kind) }
      def kind
        found = Artwork::Kind.try_deserialize(params.require(:kind).to_s)
        raise ActionController::BadRequest, "kind" unless found && Artworks::Choice::KINDS.include?(found)

        found
      end
    end
  end
end
