# typed: strict
# frozen_string_literal: true

module Playback
  # How fast one run reads its file (docs/APPLETV_STALLS.md › R1): ffmpeg's
  # -readrate and -readrate_initial_burst, chosen for the share the file is
  # on and for whether anyone is watching.
  #
  # A run that only repackages (its video copied) isn't throttled at all
  # (docs/APPLETV_STALLS.md › R2): it reads at the share's speed until the
  # supervisor pauses it far ahead of the player (Supervisor#throttle),
  # and refills at that speed once it's let go. Under -readrate a resumed
  # run went on at twice real time on ffmpeg 9, so a player that had
  # drained to the run's frontier waited there on every segment; jellyfin's
  # 7.1 happens to catch up the paused time instead. Not to depend on which.
  # Conversions keep the throttle: the encoder, not the share, is their
  # limit, and a paused play shouldn't convert the film.
  #
  # The default — a 60 s burst at disk speed, then twice real time — is
  # right on the LAN share, where the burst takes a second. On a share that
  # only just outruns the film it takes the pipe for most of a minute, and
  # a channel change starts four runs on it at once (the deck tunes the one
  # on screen and its neighbours), so the one on screen waits behind three
  # nobody is watching. There: a burst the share can deliver in a few
  # seconds, and a neighbour tuned ahead reads only enough to preroll, at
  # real time. Elsewhere a neighbour reads far enough ahead to stay in
  # front of what the deck keeps buffered for it.
  class Pace < T::Struct
    extend T::Sig

    # A share that can't read the film at this many times real time is slow.
    SLOW_HEADROOM = 8.0
    # Below this headroom a viewer is told the file can't keep up. Not 1.0: a
    # reading comes in low, a short window with a cold open inside it (1.25
    # MB/s for a share that reads 2.8, 8.9 for one that reads 90), and
    # warning about a film that plays fine is worse than missing a close one.
    BEHIND_HEADROOM = 0.5
    # On a slow share, a burst sized to about this many seconds of reading.
    BURST_READ_SECONDS = 8.0
    # And never less than this much film: the next segments and a little.
    MIN_BURST = 10.0
    # A channel tuned ahead: enough to preroll, then real time.
    STANDBY_BURST = 6.0
    STANDBY_RATE = 1.0
    # A channel tuned ahead on a share that isn't slow: past the 10 s the web
    # deck keeps buffered on standby, by a long GOP. At 6 s the deck asked
    # for what the run hadn't read yet on every fetch, and each waited
    # seconds at the frontier, holding a Puma thread (Glass, 2026-10-20).
    STANDBY_AHEAD_BURST = 20.0

    const :rate, Float
    const :burst, Float
    # -readrate at all: false for a run that only repackages.
    const :throttled, T::Boolean, default: true
    # The library root the file is under, and how fast it reads (bytes/s).
    const :root, T.nilable(String), default: nil
    const :share_speed, T.nilable(Float), default: nil
    # The file's bytes per second of film.
    const :bitrate, T.nilable(Float), default: nil
    const :standby, T::Boolean, default: false

    sig { returns(T::Boolean) }
    def slow?
      headroom = self.headroom
      !headroom.nil? && headroom < SLOW_HEADROOM
    end

    # Whether the share clearly can't deliver this file as fast as it plays.
    sig { returns(T::Boolean) }
    def falls_behind?
      headroom = self.headroom
      !headroom.nil? && headroom < BEHIND_HEADROOM
    end

    # How many times real time the share reads this file, when known.
    sig { returns(T.nilable(Float)) }
    def headroom
      speed = share_speed
      rate = bitrate
      return nil if speed.nil? || rate.nil? || !rate.positive?

      speed / rate
    end

    # `converting`: the run makes new video (a conversion, or a smaller
    # version), rather than copying the file's.
    sig { params(session: PlaybackSession, converting: T::Boolean).returns(Pace) }
    def self.for(session, converting: !session.video_copy?)
      file = session.media_file
      root = file && root_of(file)
      bitrate = file && bitrate_of(file)
      speed = root && ShareSpeed.read(root)
      base = new(rate: FfmpegArgs.readrate, burst: FfmpegArgs.readrate_burst, root: root, share_speed: speed, bitrate: bitrate,
        standby: session.standby)
      choose(base, converting: converting)
    end

    # The rate and burst for what's known of the share and the session.
    sig { params(base: Pace, converting: T::Boolean).returns(Pace) }
    def self.choose(base, converting: true)
      if base.standby
        burst = base.slow? ? STANDBY_BURST : STANDBY_AHEAD_BURST
        return with(base, rate: [ STANDBY_RATE, base.rate ].min, burst: [ burst, base.burst ].min)
      end
      return with(base, rate: base.rate, burst: base.burst, throttled: false) unless converting
      return base unless base.slow?

      headroom = T.must(base.headroom)
      with(base, rate: base.rate, burst: (headroom * BURST_READ_SECONDS).clamp([ MIN_BURST, base.burst ].min, base.burst).round(1))
    end

    sig { params(base: Pace, rate: Float, burst: Float, throttled: T::Boolean).returns(Pace) }
    def self.with(base, rate:, burst:, throttled: true)
      new(rate: rate, burst: burst, throttled: throttled, root: base.root, share_speed: base.share_speed, bitrate: base.bitrate,
        standby: base.standby)
    end

    # The root as Settings › Libraries has it, by the path as stored: no
    # filesystem call on the way to starting a run.
    sig { params(file: MediaFile).returns(T.nilable(String)) }
    def self.root_of(file)
      path = file.path.to_s
      file.library&.roots&.find { |root| path == root || path.start_with?("#{root}/") }
    end

    sig { params(file: MediaFile).returns(T.nilable(Float)) }
    def self.bitrate_of(file)
      bits = file.bit_rate
      return bits / 8.0 if bits&.positive?

      duration = file.duration_seconds
      duration&.positive? && file.size.positive? ? file.size / duration : nil
    end
  end
end
