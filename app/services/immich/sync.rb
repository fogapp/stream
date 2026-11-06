# typed: strict
# frozen_string_literal: true

module Immich
  # Brings what Immich knows about the household's home videos across
  # (PROPOSAL §5.4): who's in them, where and when (Immich's local time, a
  # wall clock), their descriptions and favourites, and their albums.
  # Read-only; a clip is found by its file, through the path mapping. A
  # video Stream hasn't read yet is picked up on the next sync.
  class Sync
    extend T::Sig

    Counts = T.type_alias { T::Hash[String, Integer] }

    sig { params(setting: ImmichSetting).void }
    def initialize(setting)
      @setting = setting
      @client = T.let(Client.new(setting), Client)
      @counts = T.let({}, Counts)
      @clips_by_immich = T.let({}, T::Hash[String, Clip])
      @clips_by_path = T.let({}, T::Hash[String, Clip])
      @people_of_clip = T.let({}, T::Hash[String, T::Array[String]])
    end

    sig { returns(Counts) }
    def call
      people = sync_people
      load_clips
      clips_by_asset = sync_videos(people)
      sync_albums(clips_by_asset)
      @setting.update!(last_synced_at: Time.current, last_sync_error: nil, last_sync_counts: @counts)
      @counts
    rescue UpstreamHttpClient::Error => e
      @setting.update!(last_sync_error: e.message.truncate(300), last_sync_counts: @counts)
      Activity.record(source: "immich", event: "immich.sync_failed", severity: Activity::Severity::Warn,
        household_id: @setting.household_id, summary: "Couldn't sync with Immich: #{e.message.truncate(200)}")
      @counts
    end

    private

    sig { params(key: String).void }
    def bump(key)
      @counts[key] = @counts.fetch(key, 0) + 1
    end

    sig { returns(T::Hash[String, HomePerson]) }
    def sync_people
      known = HomePerson.unscoped.where(household_id: @setting.household_id).index_by(&:immich_id)
      @client.people.to_h do |person|
        id = person["id"].to_s
        row = known[id] || HomePerson.unscoped.new(household_id: @setting.household_id, immich_id: id)
        row.name = person["name"].to_s.strip
        created = row.new_record?
        row.save! if row.changed?
        SyncArtworkJob.perform_later("HomePerson", row.id) if created
        bump("people")
        [ row.immich_id, row ]
      end
    end

    sig { params(people: T::Hash[String, HomePerson]).returns(T::Hash[String, Clip]) }
    def sync_videos(people)
      found = T.let({}, T::Hash[String, Clip])
      @client.each_video do |asset|
        bump("videos_in_immich")
        clip = clip_for(asset)
        if clip.nil?
          bump("not_found_in_stream")
          next
        end

        apply(clip, asset, people)
        found[asset["id"].to_s] = clip
        bump("clips_updated")
      end
      found
    end

    # Every clip and who's in it, up front: Immich lists a video at a time,
    # and a library of them is every video, every six hours.
    sig { void }
    def load_clips
      clips = Clip.unscoped.where(household_id: @setting.household_id).to_a
      by_id = clips.index_by(&:id)
      @clips_by_immich = clips.select(&:immich_id).index_by { |clip| clip.immich_id.to_s }
      Edition.where(playable_type: "Clip", playable_id: by_id.keys).joins(:media_file).pluck("media_files.path", :playable_id).each do |path, clip_id|
        clip = by_id[clip_id]
        @clips_by_path[path] = clip if clip
      end
      @people_of_clip = ClipPerson.where(clip_id: by_id.keys).pluck(:clip_id, :home_person_id)
        .group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
    end

    sig { params(asset: T::Hash[String, T.untyped]).returns(T.nilable(Clip)) }
    def clip_for(asset)
      @clips_by_immich[asset["id"].to_s] || @clips_by_path[@setting.local_path(asset["originalPath"].to_s)]
    end

    sig { params(clip: Clip, asset: T::Hash[String, T.untyped], people: T::Hash[String, HomePerson]).void }
    def apply(clip, asset, people)
      exif = asset["exifInfo"].is_a?(Hash) ? asset["exifInfo"] : {}
      # localDateTime is the clock where it was taken, labelled UTC.
      local = asset["localDateTime"].presence && Time.zone.parse(asset["localDateTime"].to_s)
      clip.immich_id = asset["id"].to_s
      clip.assign_unlocked(
        city: exif["city"].presence, country: exif["country"].presence, latitude: exif["latitude"], longitude: exif["longitude"],
        description: exif["description"].presence, favorite: asset["isFavorite"] == true
      )
      if local && !clip.locked_fields.include?("captured_at")
        clip.assign_attributes(captured_at: local.utc, captured_source: Clip::CapturedSource::Immich.serialize, captured_floating: true)
      end
      clip.save! if clip.changed?

      wanted = Array(asset["people"]).filter_map { |person| people[person["id"].to_s]&.id }
      current = @people_of_clip.fetch(clip.id, [])
      gone = current - wanted
      ClipPerson.where(clip: clip, home_person_id: gone).delete_all if gone.any?
      (wanted - current).each { |id| ClipPerson.create!(clip: clip, home_person_id: id) }
      @people_of_clip[clip.id] = wanted
    end

    sig { params(clips_by_asset: T::Hash[String, Clip]).void }
    def sync_albums(clips_by_asset)
      seen = @client.albums.filter_map do |remote|
        id = remote["id"].to_s
        clips = @client.album_asset_ids(id).filter_map { |asset_id| clips_by_asset[asset_id] }
        next if clips.empty? # an album of photos only

        album = Album.unscoped.find_or_initialize_by(household_id: @setting.household_id, immich_id: id)
        album.assign_attributes(title: remote["albumName"].presence || "Album", description: remote["description"].presence)
        album.save! if album.changed?
        AlbumClip.where(album: album).where.not(clip_id: clips.map(&:id)).delete_all
        (clips.map(&:id) - AlbumClip.where(album: album).pluck(:clip_id)).each { |clip_id| AlbumClip.create!(album: album, clip_id: clip_id) }
        bump("albums")
        id
      end
      Album.unscoped.where(household_id: @setting.household_id).where.not(immich_id: nil).where.not(immich_id: seen).destroy_all
    end
  end
end
