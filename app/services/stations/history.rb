# typed: strict
# frozen_string_literal: true

module Stations
  # What a channel has aired, as the scheduler needs it (PROPOSAL §7.7):
  # where each block's cursors stand — derived from the airings themselves,
  # so a rebuild that drops the future rolls them back with it — and what
  # aired recently enough not to repeat.
  class History
    extend T::Sig

    sig { params(station: Station, since: ActiveSupport::TimeWithZone).void }
    def initialize(station, since:)
      @since = since
      # Kept as airings are added (in the order they air), so a pick asks
      # in constant time rather than scanning a week of entries: each
      # block's last, the last of each series in it, and how many of the
      # same series it has aired in a row.
      @last_in = T.let({}, T::Hash[String, Candidate])
      @last_of = T.let({}, T::Hash[[ String, String ], Candidate])
      @runs = T.let({}, T::Hash[String, [ String, Integer ]])
      @recent = T.let({}, T::Hash[String, ActiveSupport::TimeWithZone])
      airings = Airing.unscoped.where(station_id: station.id)
      Airing.unscoped.where(station_id: station.id).where(starts_at: since..).pluck(:playable_id, :starts_at).each do |id, at|
        @recent[id] = at if @recent[id].nil? || at > T.must(@recent[id])
      end
      # Each block's last few, and the last of every series in each block:
      # enough for rotations, marathons and shows in order.
      rows = airings.where.not(station_block_id: nil)
        .select("DISTINCT ON (station_block_id, series_key) station_block_id, series_key, playable_type, playable_id, starts_at")
        .order(:station_block_id, :series_key, starts_at: :desc).to_a
      tail = airings.where.not(station_block_id: nil).where(starts_at: (since - 2.days)..).order(:starts_at).to_a
      load_entries((rows + tail).uniq { |row| [ row.station_block_id, row.playable_id, row.starts_at ] }.sort_by(&:starts_at))
    end

    sig { params(block_id: String, candidate: Candidate, starts_at: ActiveSupport::TimeWithZone).void }
    def add(block_id, candidate, starts_at)
      record(block_id, candidate)
      @recent[candidate.playable_id] = starts_at
    end

    sig { params(block_id: String).returns(T.nilable(Candidate)) }
    def last_in(block_id) = @last_in[block_id]

    sig { params(block_id: String, series_key: String).returns(T.nilable(Candidate)) }
    def last_of(block_id, series_key) = @last_of[[ block_id, series_key ]]

    # How many of the block's latest airings in a row are the same series.
    sig { params(block_id: String).returns(Integer) }
    def run_length(block_id) = @runs[block_id]&.last || 0

    sig { params(playable_id: String).returns(T::Boolean) }
    def aired_recently?(playable_id) = @recent.key?(playable_id)

    sig { params(playable_id: String).returns(T.nilable(ActiveSupport::TimeWithZone)) }
    def last_aired(playable_id) = @recent[playable_id]

    private

    # Airing rows as candidates, with what ordering needs to find the next
    # one when the last is no longer in the pool.
    sig { params(rows: T::Array[Airing]).void }
    def load_entries(rows)
      episodes = Episode.where(id: rows.select { |row| row.playable_type == "Episode" }.map(&:playable_id)).includes(:show).index_by(&:id)
      videos = Video.unscoped.where(id: rows.select { |row| row.playable_type == "Video" }.map(&:playable_id)).includes(:channel)
        .index_by(&:id)
      # A film's place among films is its release, as Source dates it.
      movies = Movie.unscoped.where(id: rows.select { |row| row.playable_type == "Movie" }.map(&:playable_id))
        .pluck(:id, :title, Arel.sql("COALESCE(release_date, make_date(year, 1, 1))")).to_h { |id, title, released| [ id, [ title, released ] ] }
      rows.each do |row|
        episode = episodes[row.playable_id]
        video = videos[row.playable_id]
        movie_title, released = movies[row.playable_id]
        candidate = Candidate.new(playable_type: row.playable_type, playable_id: row.playable_id, media_file_id: "", duration: 0.0,
          series_key: row.series_key, series_title: episode&.show&.title || video&.channel&.title || movie_title.to_s,
          season: episode&.season_number.to_i, episode: episode&.episode_number.to_i,
          aired_on: episode&.air_date || video&.upload_date || released)
        record(T.must(row.station_block_id), candidate)
      end
    end

    sig { params(block_id: String, candidate: Candidate).void }
    def record(block_id, candidate)
      key = candidate.series_key
      @last_in[block_id] = candidate
      @last_of[[ block_id, key ]] = candidate
      series, count = @runs[block_id]
      @runs[block_id] = [ key, series == key && count ? count + 1 : 1 ]
    end
  end
end
