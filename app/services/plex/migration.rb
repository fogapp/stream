# typed: strict
# frozen_string_literal: true

module Plex
  # A dry run or an import from Plex (PROPOSAL §7.4): each user's watch
  # history and star ratings, and the server's collections and the titles,
  # summaries and posters people chose there (their locked fields).
  #
  # The rule that makes re-runs safe: the newer view wins. A Plex view that
  # is older than what Stream already knows is left alone (and counted), so
  # running the import twice changes nothing the second time, and anything
  # watched in Plex since the last run arrives on the next.
  class Migration
    extend T::Sig

    Counts = T.type_alias { T::Hash[String, Integer] }

    sig { params(import: PlexImport).void }
    def initialize(import)
      @import = import
      @connection = T.let(PlexConnection.unscoped.find_by!(household_id: import.household_id), PlexConnection)
      @counts = T.let({}, Counts)
      @unmatched = T.let([], T::Array[T::Hash[String, T.untyped]])
      @users = T.let([], T::Array[T::Hash[String, T.untyped]])
      @shows = T.let({}, T::Hash[String, Show])
      # Plex items with fields a person locked, and the Stream title each is.
      @customized = T.let([], T::Array[[ T::Hash[String, T.untyped], T.any(Movie, Show) ]])
    end

    sig { void }
    def call
      @import.update!(status: PlexImport::Status::Running.serialize, started_at: Time.current)
      admin = Server.for(@connection)
      machine = admin.identity["machineIdentifier"].to_s
      catalog = Catalog.new(@import.household_id)
      matches = match_everything(admin, catalog)
      import_customizations(admin)
      import_collections(admin, matches)
      @connection.plex_user_mappings.where.not(profile_id: nil).includes(:profile).find_each do |mapping|
        import_user(mapping, matches, machine)
      end
      @import.update!(status: PlexImport::Status::Succeeded.serialize, finished_at: Time.current, counts: @counts,
        unmatched: @unmatched.first(PlexImport::UNMATCHED_KEPT), users: @users)
      @connection.update!(last_synced_at: Time.current) unless @import.dry_run
      record
    rescue UpstreamHttpClient::Error => e
      # Plex unreachable or refusing: said on the import, and that's all.
      failed!(e.message)
    rescue StandardError => e
      # Anything else is a bug, and goes on to the job's error reporting —
      # but never leaves the import running forever with nothing said
      # (CLAUDE.md invariant 5).
      failed!("#{e.class}: #{e.message}")
      raise
    end

    private

    sig { params(message: String).void }
    def failed!(message)
      @import.update!(status: PlexImport::Status::Failed.serialize, finished_at: Time.current, error: message.truncate(500),
        counts: @counts, users: @users)
      Activity.record(source: "plex", event: "plex.import_failed", severity: Activity::Severity::Error, subject: @import,
        household_id: @import.household_id, summary: "Plex #{@import.dry_run ? 'dry run' : 'import'} failed: #{message.truncate(200)}")
    end

    # Every Plex movie and episode, resolved to a Stream playable (or not)
    # by ratingKey.
    sig { params(server: Server, catalog: Catalog).returns(T::Hash[String, Catalog::Match]) }
    def match_everything(server, catalog)
      matches = {}
      server.sections.each do |section|
        key = section["key"].to_s
        case section["type"]
        when "movie"
          server.each_item(key, type: Server::MOVIE) do |item|
            match = catalog.movie(item)
            resolve(matches, item, match, "movie")
            playable = match&.playable
            @customized << [ item, playable ] if playable.is_a?(Movie) && customized?(item)
          end
        when "show"
          server.each_item(key, type: Server::SHOW) do |item|
            catalog.remember_show(item)
            show = catalog.show(item)
            next if show.nil?

            @shows[item["ratingKey"].to_s] = show
            @customized << [ item, show ] if customized?(item)
          end
          server.each_item(key, type: Server::EPISODE) { |item| resolve(matches, item, catalog.episode(item), "episode") }
        end
      end
      matches
    end

    sig do
      params(matches: T::Hash[String, Catalog::Match], item: T::Hash[String, T.untyped], match: T.nilable(Catalog::Match),
        kind: String).void
    end
    def resolve(matches, item, match, kind)
      bump(@counts, "#{kind}s_in_plex", 1)
      if match
        matches[item["ratingKey"].to_s] = match
        bump(@counts, "#{kind}s_matched", 1)
        bump(@counts, "matched_by_#{match.how.parameterize(separator: '_')}", 1)
      elsif @unmatched.size < PlexImport::UNMATCHED_KEPT
        label = kind == "movie" ? "#{item['title']} (#{item['year']})" : "#{item['grandparentTitle']} S#{item['parentIndex']}E#{item['index']}"
        @unmatched << { "kind" => kind, "title" => label }
      end
    end

    sig { params(mapping: PlexUserMapping, matches: T::Hash[String, Catalog::Match], machine: String).void }
    def import_user(mapping, matches, machine)
      profile = T.must(mapping.profile)
      tally = T.let({}, Counts)
      server = user_server(mapping, machine)
      server.sections.each do |section|
        types = { "movie" => [ Server::MOVIE ], "show" => [ Server::SHOW, Server::EPISODE ] }.fetch(section["type"].to_s, [])
        types.each do |type|
          # A page's views and stars read together, not an item at a time.
          server.each_page(section["key"].to_s, type: type) do |items|
            if type == Server::SHOW
              shows = items.filter_map { |item| (show = @shows[item["ratingKey"].to_s]) && [ item, show ] }
              ratings = Rating.index_for(profile, shows.map(&:last))
              shows.each { |item, show| apply_rating(profile, show, item, tally, ratings) }
              next
            end
            found = items.filter_map { |item| (match = matches[item["ratingKey"].to_s]) && [ item, match ] }
            playables = found.map { |_, match| match.playable }
            ratings = Rating.index_for(profile, playables)
            states = WatchState.index_for(profile, playables)
            found.each do |item, match|
              apply_rating(profile, match.playable, item, tally, ratings)
              apply(profile, match, item, tally, states)
            end
          end
        end
      end
      import_playlists(server, profile, matches, tally)
      @users << { "plex_name" => mapping.plex_name, "profile" => profile.name }.merge(tally)
      tally.each { |key, count| bump(@counts, key, count) }
    rescue UpstreamHttpClient::Error => e
      @users << { "plex_name" => mapping.plex_name, "profile" => mapping.profile&.name, "error" => e.message.truncate(200) }
    end

    sig { params(mapping: PlexUserMapping, machine: String).returns(Server) }
    def user_server(mapping, machine)
      return Server.for(@connection) if mapping.plex_admin

      account = Account.new(token: @connection.token.to_s, client_id: @connection.household_id)
      user = Account::HomeUser.new(id: mapping.plex_user_id, uuid: mapping.plex_uuid, name: mapping.plex_name, admin: false,
        protected: false)
      Server.for(@connection, token: account.server_token_for(user, machine_identifier: machine))
    end

    sig do
      params(profile: Profile, match: Catalog::Match, item: T::Hash[String, T.untyped], tally: T::Hash[String, Integer],
        states: T::Hash[[ String, String ], WatchState]).void
    end
    def apply(profile, match, item, tally, states)
      views = item["viewCount"].to_i
      offset = item["viewOffset"].to_i / 1000.0
      return if views.zero? && offset.zero?

      viewed_at = Time.zone.at(item["lastViewedAt"].to_i)
      playable = match.playable
      state = states.fetch([ playable.class.polymorphic_name, playable.id ]) { WatchState.find_or_initialize_by(profile: profile, playable: playable) }
      known = state.last_watched_at
      if known && known >= viewed_at
        bump(tally, known == viewed_at ? "unchanged" : "newer_in_stream", 1)
        return
      end

      in_progress = offset >= WatchState::STARTED_AFTER
      bump(tally, in_progress ? "in_progress_imported" : "watched_imported", 1)
      return if @import.dry_run

      state.assign_attributes(last_watched_at: viewed_at, play_count: [ state.play_count, views ].max,
        duration_seconds: state.duration_seconds || (item["duration"].to_i / 1000.0).nonzero?)
      if in_progress
        state.assign_attributes(position_seconds: offset, completed_at: nil)
      else
        state.assign_attributes(position_seconds: 0, completed_at: viewed_at)
      end
      state.save!
    end

    # Stars, out of 10 as Plex keeps them. The newer rating wins, as views do.
    sig do
      params(profile: Profile, rateable: T.any(Movie, Show, Episode), item: T::Hash[String, T.untyped],
        tally: T::Hash[String, Integer], ratings: T::Hash[[ String, String ], Rating]).void
    end
    def apply_rating(profile, rateable, item, tally, ratings)
      value = item["userRating"]&.to_f
      return if value.nil? || !value.positive?

      rated_at = Time.zone.at((item["lastRatedAt"] || item["lastViewedAt"] || item["updatedAt"]).to_i)
      rating = ratings.fetch([ rateable.class.polymorphic_name, rateable.id ]) { Rating.find_or_initialize_by(profile: profile, rateable: rateable) }
      if rating.persisted? && rating.rated_at >= rated_at
        bump(tally, "ratings_unchanged", 1)
        return
      end

      bump(tally, "ratings_imported", 1)
      rating.update!(value: value.clamp(0.5, 10.0), rated_at: rated_at) unless @import.dry_run
    end

    # A user's own playlists become their profile's; a smart one comes over
    # as what Plex lists in it today (a later sync adds what's new). Items
    # added in Stream stay.
    sig do
      params(server: Server, profile: Profile, matches: T::Hash[String, Catalog::Match], tally: T::Hash[String, Integer]).void
    end
    def import_playlists(server, profile, matches, tally)
      server.playlists.each do |plex|
        bump(tally, "smart_playlists_snapshotted", 1) if [ true, 1, "1" ].include?(plex["smart"])

        items = server.playlist_items(plex["ratingKey"].to_s).filter_map { |item| matches[item["ratingKey"].to_s]&.playable }
        bump(tally, "playlists_imported", 1)
        bump(tally, "playlist_items_imported", items.size)
        next if @import.dry_run

        playlist = Playlist.unscoped.find_or_initialize_by(profile_id: profile.id, plex_key: plex["ratingKey"].to_s)
        playlist.assign_attributes(household_id: profile.household_id, title: plex["title"].presence || "Playlist")
        playlist.save!
        items.each_with_index do |item, index|
          PlaylistItem.find_or_create_by!(playlist: playlist, item: item) { |row| row.position = index }
        end
      end
    end

    # Plex's names for the fields a person can lock, and Stream's.
    CUSTOM_FIELDS = T.let({
      "title" => "title", "originalTitle" => "original_title", "summary" => "overview", "tagline" => "tagline",
      "contentRating" => "content_rating", "year" => "year", "originallyAvailableAt" => "release_date", "genre" => "genres"
    }.freeze, T::Hash[String, String])
    CUSTOM_PICTURES = T.let({ "thumb" => Artwork::Kind::Poster, "art" => Artwork::Kind::Backdrop }.freeze,
      T::Hash[String, Artwork::Kind])

    sig { params(item: T::Hash[String, T.untyped]).returns(T::Array[String]) }
    def locked_names(item)
      Array(item["Field"]).select { |field| [ true, 1, "1" ].include?(field["locked"]) }.map { |field| field["name"].to_s }
    end

    sig { params(item: T::Hash[String, T.untyped]).returns(T::Boolean) }
    def customized?(item) = locked_names(item).any? { |name| CUSTOM_FIELDS.key?(name) || CUSTOM_PICTURES.key?(name) }

    # What people changed in Plex arrives changed and locked here — unless
    # someone has since changed it in Stream, which wins.
    sig { params(server: Server).void }
    def import_customizations(server)
      @customized.each do |item, listed|
        # The catalog holds only what matching needs; this writes the rest.
        title = T.unsafe(listed.class).unscoped.find(listed.id)
        names = locked_names(item)
        changes = names.filter_map do |name|
          field = CUSTOM_FIELDS[name]
          next if field.nil? || !title.has_attribute?(field) || title.locked_fields.include?(field)

          value = case name
          when "genre" then Array(item["Genre"]).filter_map { |genre| genre["tag"].presence }
          when "year" then item["year"]&.to_i
          else item[name].presence
          end
          [ field, value ]
        end.to_h
        pictures = names.filter_map do |name|
          kind = CUSTOM_PICTURES[name]
          path = item[name].to_s
          [ kind, path ] if kind && path.present? && !title.locked_fields.include?("#{kind.serialize}_path")
        end
        bump(@counts, "custom_fields_imported", changes.size)
        bump(@counts, "custom_pictures_imported", pictures.size)
        next if @import.dry_run

        if changes.any?
          title.assign_attributes(changes)
          title.locked_fields = (title.locked_fields | changes.keys).sort
          title.save!
        end
        pictures.each { |kind, path| import_picture(server, title, kind, path) }
      end
    end

    sig { params(server: Server, owner: T.any(Movie, Show, Collection), kind: Artwork::Kind, path: String).void }
    def import_picture(server, owner, kind, path)
      artwork = Artwork.find_or_initialize_by(owner: owner, kind: kind.serialize)
      return if artwork.ready? && artwork.source_enum == Artwork::Source::Plex && artwork.source_ref == path

      artwork.update!(source: Artwork::Source::Plex.serialize, source_ref: path)
      Tempfile.create([ "plex", ".img" ]) do |file|
        server.download(path, into: Pathname.new(file.path))
        Artworks::Publish.call(artwork, source: file.path)
      end
      owner.update!(locked_fields: (owner.locked_fields | [ "#{kind.serialize}_path" ]).sort)
    rescue UpstreamHttpClient::Error, Artworks::Renderer::Error, ToolRunner::Error => e
      bump(@counts, "custom_pictures_failed", 1)
      artwork&.update!(state: artwork.ready? ? Artwork::State::Ready.serialize : Artwork::State::Failed.serialize,
        last_error: e.message.truncate(300))
    end

    # The server's collections become the household's own. A smart one (a
    # saved filter) becomes a Stream smart collection when its filter says
    # nothing Stream can't (Plex::SmartFilter), and otherwise comes over as
    # what Plex lists in it today. Titles added in Stream stay.
    sig { params(server: Server, matches: T::Hash[String, Catalog::Match]).void }
    def import_collections(server, matches)
      server.sections.each do |section|
        next unless %w[movie show].include?(section["type"].to_s)

        genres = T.let(nil, T.nilable(T::Hash[String, String]))
        server.collections(section["key"].to_s).each do |plex|
          bump(@counts, "collections_in_plex", 1)
          if [ true, 1, "1" ].include?(plex["smart"])
            genres ||= server.genres(section["key"].to_s)
            filter = SmartFilter.translate(plex["content"].to_s, genres: genres)
            if filter.complete?
              import_smart_collection(plex, filter)
              next
            end
            bump(@counts, "smart_collections_snapshotted", 1)
          end

          members = server.collection_items(plex["ratingKey"].to_s).filter_map do |child|
            key = child["ratingKey"].to_s
            playable = matches[key]&.playable
            @shows[key] || (playable.is_a?(Movie) ? playable : nil)
          end
          bump(@counts, "collections_imported", 1)
          bump(@counts, "collection_items_imported", members.size)
          next if @import.dry_run

          collection = Collection.unscoped.find_or_initialize_by(household_id: @import.household_id, plex_key: plex["ratingKey"].to_s)
          collection.kind = Collection::Kind::Manual.serialize if collection.new_record?
          collection.assign_unlocked(title: plex["title"].presence || "Collection", overview: plex["summary"].presence)
          collection.save!
          members.each_with_index do |member, index|
            CollectionItem.find_or_create_by!(collection: collection, item: member) { |row| row.position = index }
          end
          thumb = plex["thumb"].to_s
          import_picture(server, collection, Artwork::Kind::Poster, thumb) if thumb.present? && locked_names(plex).include?("thumb")
        end
      end
    end

    sig { params(plex: T::Hash[String, T.untyped], filter: SmartFilter::Result).void }
    def import_smart_collection(plex, filter)
      bump(@counts, "smart_collections_imported", 1)
      return if @import.dry_run

      collection = Collection.unscoped.find_or_initialize_by(household_id: @import.household_id, plex_key: plex["ratingKey"].to_s)
      collection.kind = Collection::Kind::Smart.serialize if collection.new_record?
      collection.assign_unlocked(title: plex["title"].presence || "Collection", overview: plex["summary"].presence)
      collection.rules = filter.rules if collection.smart?
      collection.save!
    end

    sig { params(counts: Counts, key: String, by: Integer).void }
    def bump(counts, key, by = 1)
      counts[key] = counts.fetch(key, 0) + by
    end

    sig { void }
    def record
      verb = @import.dry_run ? "Dry run" : "Import"
      c = ->(key) { @counts.fetch(key, 0) }
      summary = "#{verb} from Plex: #{c.call('movies_matched')}/#{c.call('movies_in_plex')} movies and " \
                "#{c.call('episodes_matched')}/#{c.call('episodes_in_plex')} episodes matched; " \
                "#{c.call('watched_imported')} watched and #{c.call('in_progress_imported')} in progress " \
                "#{@import.dry_run ? 'would be' : 'were'} imported"
      Activity.record(source: "plex", event: @import.dry_run ? "plex.dry_run" : "plex.imported", subject: @import,
        household_id: @import.household_id, summary: summary, payload: @counts)
    end
  end
end
