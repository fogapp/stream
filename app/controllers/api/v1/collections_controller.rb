# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Collections (PROPOSAL §4.2): everyone browses them; an admin makes
    # them, fills them and edits them.
    class CollectionsController < BaseController
      # Only a page answers to Viewing::Access: what an admin changes it finds whoever they're watching as.
      finds :collection, from: -> { T.unsafe(self).action_name == "show" ? Viewing::Access.collections(Collection.all) : Collection.all }
      skip_before_action :set_collection, only: %i[index create]
      before_action :require_admin!, except: %i[index show]

      # All of them, or a library's own and the household's that hold
      # something from it (library_id).
      sig { void }
      def index
        scope = Viewing::Access.collections(Collection.order(:sort_title)).includes(:collection_items, :library)
        library_id = params[:library_id].to_s.presence
        scope = scope.where(library_id: [ library_id, nil ]) if library_id
        collections = scope.to_a
        listed = Collection.items_for(collections)
        allowed = Viewing::Catalog.watchable_titles(listed.values.flatten.uniq).to_set
        items = listed.transform_values { |titles| titles.select { |title| allowed.include?(title) } }
        if library_id
          collections = collections.select do |collection|
            collection.library_id == library_id || items.fetch(collection.id).any? { |item| item.library_id == library_id }
          end
        end
        images = ArtworkSerializer.index(collections + items.values.flatten.uniq)
        render json: collections.map { |collection| CatalogSerializer.collection_card(collection, items.fetch(collection.id), images) }
      end

      sig { void }
      def show
        items = Viewing::Catalog.watchable_titles(collection.items)
        images = ArtworkSerializer.index([ collection ] + items)
        cards = Viewing::Cards.new(current_profile!).prime(items)
        missing = missing_parts(collection)
        part_images = ArtworkSerializer.index(missing)
        render json: CatalogSerializer.collection_card(collection, items, images).merge(
          overview: collection.overview, locked_fields: collection.locked_fields, rules: collection.smart? ? collection.rules : nil,
          pinned_to_home: pinned?("collection", collection.id),
          missing: missing.map do |part|
            { tmdb_id: part.tmdb_id, title: part.title, year: part.year, release_date: part.release_date, overview: part.overview,
              images: ArtworkSerializer.images(part_images, part) }
          end,
          items: items.map { |item| cards.card(item) }
        )
      end

      sig { void }
      def create
        smart = params[:kind].to_s == Collection::Kind::Smart.serialize
        created = Collection.new(kind: (smart ? Collection::Kind::Smart : Collection::Kind::Manual).serialize, title: params[:title].to_s.strip,
          overview: params[:overview].presence, rules: smart ? Viewing::SmartCollection.normalize(rules_param) : {})
        created.save!

        add(created, params[:item_type], params[:item_id]) if params[:item_id].present?
        render json: { id: created.id, title: created.title }, status: :created
      end

      # Edits to a TMDB collection lock the field against the next refresh.
      sig { void }
      def update
        changes = params.permit(:title, :overview).to_h
        if params.key?(:library_id)
          library = params[:library_id].presence && Library.find(params[:library_id].to_s)
          collection.library = library || nil
          changes["library_id"] = collection.library_id
        end
        collection.assign_attributes(changes.except("library_id"))
        collection.rules = Viewing::SmartCollection.normalize(rules_param) if collection.smart? && params.key?(:rules)
        # A household's own collection needs no lock, unless a Plex import could overwrite it.
        collection.locked_fields = (collection.locked_fields + changes.keys).uniq if collection.kind_enum == Collection::Kind::Tmdb || collection.plex_key
        collection.save!

        show
      end

      sig { void }
      def destroy
        return render_errors("TMDB's collections come back with their films; only your own can be deleted") if collection.kind_enum == Collection::Kind::Tmdb

        collection.destroy!
        head :no_content
      end

      sig { void }
      def add_item
        add(collection, params.require(:item_type), params.require(:item_id))
        head :no_content
      end

      sig { void }
      def remove_item
        CollectionItem.where(collection: collection, item_type: item_class(params.require(:item_type)).name,
          item_id: params.require(:item_id).to_s).delete_all
        head :no_content
      end

      # { ids: [item ids in the new order] }
      sig { void }
      def reorder
        CollectionItem.reposition!(collection.collection_items, Array(params[:ids]).map(&:to_s))
        head :no_content
      end

      private

      sig { returns(T::Hash[String, T.untyped]) }
      def rules_param
        raw = params[:rules]
        raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h.to_h.to_hash : {}
      end

      sig { params(target: Collection, type: T.untyped, id: T.untyped).void }
      def add(target, type, id)
        item = item_class(type.to_s).find(id.to_s)
        last = target.collection_items.maximum(:position).to_i
        CollectionItem.find_or_create_by!(collection: target, item: item) { |row| row.position = last + 1 }
      rescue ActiveRecord::RecordNotUnique
        nil
      end

      sig { params(type: String).returns(T.any(T.class_of(Movie), T.class_of(Show))) }
      def item_class(type)
        case type
        when "movie" then Movie
        when "show" then Show
        else raise ActiveRecord::RecordNotFound
        end
      end

      # A TMDB collection's films no library has, to show faded. Not for a
      # profile with a rating ceiling or a curated one: TMDB doesn't say what
      # they're rated.
      # One the household has but this profile can't see isn't missing.
      sig { params(collection: Collection).returns(T::Array[CollectionPart]) }
      def missing_parts(collection)
        return [] unless collection.kind_enum == Collection::Kind::Tmdb
        return [] if current_profile!.curated || !current_profile!.max_rating_age.nil?

        parts = collection.parts.to_a
        had = Movie.where(tmdb_id: parts.map(&:tmdb_id)).pluck(:tmdb_id).to_set
        parts.reject { |part| had.include?(part.tmdb_id) }
      end

      sig { params(kind: String, id: String).returns(T::Boolean) }
      def pinned?(kind, id) = Array(current_profile!.home_layout["pinned"]).any? { |pin| pin["kind"] == kind && pin["id"] == id }
    end
  end
end
