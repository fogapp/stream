# typed: strict
# frozen_string_literal: true

# The Grid's shapes (PROPOSAL §7.7): a channel in the guide, its programming
# for the editor, and what's on it when.
module StationSerializer
  extend T::Sig

  sig { params(station: Station, hidden: T::Boolean, favorite: T::Boolean).returns(T::Hash[Symbol, T.untyped]) }
  def self.station_json(station, hidden: false, favorite: false)
    { id: station.id, number: station.number, name: station.name, call_sign: station.call_sign, hidden: hidden, favorite: favorite,
      live_stream_id: station.live_stream_id }
  end

  # Everything the channel editor shows.
  sig { params(station: Station).returns(T::Hash[Symbol, T.untyped]) }
  def self.config_json(station)
    station_json(station).merge(
      snap_minutes: station.snap_minutes, no_repeat_days: station.no_repeat_days, filler: station.filler, breaks: station.breaks,
      filler_channel_ids: station.filler_channel_ids, mlb_team_ids: station.mlb_team_ids,
      scheduled_through: station.scheduled_through&.iso8601, last_scheduled_at: station.last_scheduled_at&.iso8601,
      last_error: station.last_error, blocks: station.station_blocks.map { |block| block_json(block) }
    )
  end

  sig { params(block: StationBlock).returns(T::Hash[Symbol, T.untyped]) }
  def self.block_json(block)
    {
      id: block.id, layer: block.layer, name: block.name, label: block.label, days: block.days,
      start_minute: block.start_minute, end_minute: block.end_minute, starts_on: block.starts_on&.iso8601,
      ends_on: block.ends_on&.iso8601, source: block.source, ordering: block.ordering, marathon_length: block.marathon_length,
      loops: block.loops
    }
  end

  # A stream's channel in the guide (PROPOSAL §7.8): one program, the stream,
  # across the whole window asked for. Not a row: nothing is scheduled; its
  # id is a UUID made from the station's, the same in every window.
  sig do
    params(station: Station, stream: LiveStream, from: ActiveSupport::TimeWithZone, to: ActiveSupport::TimeWithZone)
      .returns(T::Hash[Symbol, T.untyped])
  end
  def self.stream_airing_json(station, stream, from:, to:)
    still = LiveStreams::StillUrl.for(stream)
    {
      id: Digest::UUID.uuid_v5(Digest::UUID::OID_NAMESPACE, "stream:#{station.id}"), station_id: station.id, starts_at: from.iso8601(3), ends_at: to.iso8601(3), reason: "Live",
      playable_id: stream.id, media_start: 0, media_end: nil, kind: "live_stream", title: stream.name,
      subtitle: stream.online? ? "Live" : "Offline", episode_title: nil, code: nil, show_id: nil, channel_id: nil, year: nil,
      content_rating: stream.content_rating, overview: stream.description&.truncate(400),
      images: still ? { "still" => { src: still, srcset: "", width: LiveStreams::Still::WIDTH, height: nil, placeholder: nil, color: nil } } : {},
      reminded: false, filler: false
    }
  end

  # A page of airings with their titles and pictures, loaded in a few queries.
  sig { params(airings: T::Array[Airing], reminded: T::Set[String]).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def self.airings_json(airings, reminded: Set.new)
    movies = Movie.unscoped.where(id: airings.select { |airing| airing.playable_type == "Movie" }.map(&:playable_id)).index_by(&:id)
    episodes = Episode.where(id: airings.select { |airing| airing.playable_type == "Episode" }.map(&:playable_id))
      .includes(:show).index_by(&:id)
    fillers = Extra.unscoped.where(id: airings.select { |airing| airing.playable_type == "Extra" }.map(&:playable_id)).index_by(&:id)
      .merge(Video.unscoped.where(id: airings.select { |airing| airing.playable_type == "Video" }.map(&:playable_id)).includes(:channel).index_by(&:id))
    streams = LiveStream.unscoped.where(id: airings.select { |airing| airing.playable_type == "LiveStream" }.map(&:playable_id)).index_by(&:id)
    videos = fillers.values.grep(Video)
    images = ArtworkSerializer.index(movies.values + episodes.values + episodes.values.filter_map(&:show).uniq + videos)
    airings.filter_map do |airing|
      playable =
        case airing.playable_type
        when "Movie" then movies[airing.playable_id]
        when "Episode" then episodes[airing.playable_id]
        when "LiveStream" then streams[airing.playable_id]
        else fillers[airing.playable_id]
        end
      playable && airing_json(airing, playable, images).merge(reminded: reminded.include?(airing.id), filler: airing.filler)
    end
  end

  sig do
    params(airing: Airing, playable: T.any(Movie, Episode, Extra, Video, LiveStream), images: ArtworkSerializer::Index)
      .returns(T::Hash[Symbol, T.untyped])
  end
  def self.airing_json(airing, playable, images)
    base = {
      id: airing.id, station_id: airing.station_id, starts_at: airing.starts_at.iso8601(3), ends_at: airing.ends_at.iso8601(3),
      reason: airing.reason, playable_id: playable.id, media_start: airing.media_start, media_end: airing.media_end
    }
    case playable
    when Movie
      base.merge(kind: "movie", title: playable.title, subtitle: playable.year&.to_s, episode_title: nil, code: nil, show_id: nil,
        channel_id: nil, year: playable.year, content_rating: playable.content_rating, overview: playable.overview&.truncate(400),
        images: ArtworkSerializer.images(images, playable))
    when Episode
      show = playable.show
      base.merge(kind: "episode", title: show&.title.to_s, subtitle: [ playable.code, playable.title ].compact.join(" · "),
        episode_title: playable.title, code: playable.code, show_id: show&.id, channel_id: nil, year: playable.air_date&.year || show&.year,
        content_rating: show&.content_rating, overview: (playable.overview || show&.overview)&.truncate(400),
        images: (show ? ArtworkSerializer.images(images, show) : {}).merge(ArtworkSerializer.images(images, playable)))
    when Extra
      base.merge(kind: "extra", title: playable.title, subtitle: playable.kind_label, episode_title: nil, code: nil, show_id: nil,
        channel_id: nil, year: nil, content_rating: nil, overview: nil, images: {})
    when Video
      # A video's thumbnail is its still, as an episode's is.
      base.merge(kind: "video", title: playable.title, subtitle: playable.channel&.title, episode_title: nil, code: nil, show_id: nil,
        channel_id: playable.channel_id, year: playable.upload_date&.year, content_rating: nil, overview: playable.description&.truncate(400),
        images: ArtworkSerializer.images(images, playable).transform_keys { |kind| kind == "thumb" ? "still" : kind })
    when LiveStream
      # A team's game (Stations::Games): the matchup, played from its stream.
      base.merge(kind: "live_stream", title: airing.program_title || playable.name, subtitle: airing.program_subtitle || playable.kind_enum.label,
        episode_title: nil, code: nil, show_id: nil, channel_id: nil, year: nil, content_rating: playable.content_rating,
        overview: nil, images: {})
    else T.absurd(playable)
    end
  end
end
