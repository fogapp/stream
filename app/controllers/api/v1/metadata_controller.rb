# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # An admin's corrections to a title's details, with field locks
    # (PROPOSAL §4.2), and a refresh from TMDB on demand.
    class MetadataController < BaseController
      before_action :require_admin!

      # { changes: { field: value }, unlock: [field] }
      sig { void }
      def update
        changes = params[:changes].respond_to?(:to_unsafe_h) ? params[:changes].to_unsafe_h.to_h : {}
        saved = Catalog::Editing.edit(record, changes: changes, unlock: Array(params[:unlock]).map(&:to_s))
        render json: fields_json(saved)
      rescue Catalog::Editing::Invalid => e
        render_errors(e.message)
      end

      sig { void }
      def refresh
        RefreshMetadataJob.perform_later(record.class.name.to_s, record.id)
        head :accepted
      end

      private

      sig { returns(Catalog::Editing::Record) }
      def record
        @record ||= T.let(
          case params.require(:kind).to_s
          when "movie" then Movie.find(params.require(:id))
          when "show" then Show.find(params.require(:id))
          when "episode" then Episode.joins(:show).merge(Show.all).find(params.require(:id))
          else raise ActiveRecord::RecordNotFound
          end,
          T.nilable(Catalog::Editing::Record)
        )
      end

      sig { params(saved: Catalog::Editing::Record).returns(T::Hash[String, T.untyped]) }
      def fields_json(saved)
        Catalog::Editing::FIELDS.fetch(saved.class.name.to_s).keys.to_h { |field| [ field, saved.public_send(field) ] }
          .merge("locked_fields" => saved.locked_fields)
      end
    end
  end
end
