# typed: strict
# frozen_string_literal: true

module Playback
  # What a fragment ffmpeg wrote really holds (PROPOSAL §6.3): which tracks
  # have samples in it, and where its picture starts. Read from the few KB
  # of boxes at its head — never the media — so a run's fragments can be
  # named by the GOP they are rather than the GOP that was asked for
  # (Publisher): ffmpeg decides where a seek lands, and has moved it.
  module Fragment
    extend T::Sig

    class Unreadable < StandardError; end

    # A track as the init segment describes it.
    class Track < T::Struct
      const :id, Integer
      const :video, T::Boolean
      const :timescale, Integer
      # Where presentation time zero is in the track's own time (its edit
      # list): the first frame's composition offset, with B-frames.
      const :media_time, Integer
      # How long a sample lasts when a fragment doesn't say (its trex).
      const :default_duration, T.nilable(Integer), default: nil
      # A picture's decoder configuration (avcC, hvcC, av1C, vpcC): its
      # SPS and PPS, which every fragment is decoded with. nil for sound.
      const :config, T.nilable(String), default: nil
    end

    # A track's part of one fragment.
    class Run < T::Struct
      const :track_id, Integer
      # Decode time of its first sample, in the track's timescale.
      const :decode_time, Integer
      const :first_offset, Integer
      const :samples, Integer
      # How long its samples last, in the track's timescale: what its truns
      # give, and how many samples they leave to a default (its tfhd's, or
      # failing that its track's).
      const :timed_duration, Integer, default: 0
      const :untimed_samples, Integer, default: 0
      const :default_duration, T.nilable(Integer), default: nil
    end

    # More than the boxes ahead of any fragment's media: a ten-second GOP at
    # 60 frames a second with its sound is under 20 KB of them. A fragment
    # reads only its moof of it (first_box); an init segment, all of it.
    HEAD = T.let(1024 * 1024, Integer)

    sig { params(init: T.any(String, Pathname)).returns(T::Array[Track]) }
    def self.tracks(init)
      data = File.binread(init.to_s, HEAD).to_s
      tracks = T.let([], T::Array[Track])
      defaults = T.let({}, T::Hash[Integer, Integer])
      each_box(data, 0, data.bytesize, %w[moov]) do |_, moov_at, moov_end|
        each_box(data, moov_at, moov_end, %w[trak mvex]) do |type, at, finish|
          if type == "trak"
            track = track(data, at, finish)
            tracks << track if track
          else
            each_box(data, at, finish, %w[trex]) { |_, trex_at, _| defaults[uint(data, trex_at + 4, 4)] = uint(data, trex_at + 12, 4) }
          end
        end
      end
      raise Unreadable, "#{File.basename(init.to_s)} describes no tracks" if tracks.empty?

      tracks.map { |track| defaults[track.id] ? Track.new(**track.serialize.symbolize_keys, default_duration: defaults[track.id]) : track }
    end

    # Each track's samples in a fragment (a joined segment's first GOP).
    # Only its first moof is read off the disk, not the media after it.
    sig { params(path: T.any(String, Pathname)).returns(T::Array[Run]) }
    def self.runs(path) = runs_in(first_box(path, "moof"))

    # The same, from bytes already read: the file's head (or its first moof).
    sig { params(data: String).returns(T::Array[Run]) }
    def self.runs_in(data)
      runs = T.let([], T::Array[Run])
      # The first moof only: a fragment ffmpeg writes has one.
      each_box(data, 0, data.bytesize, %w[moof]) do |_, moof_at, moof_end|
        each_box(data, moof_at, moof_end, %w[traf]) do |_, traf_at, traf_end|
          run = run(data, traf_at, traf_end)
          runs << run if run && runs.none? { |known| known.track_id == run.track_id }
        end
        break
      end
      runs
    end

    # Where the fragment's picture starts and where it ends, in
    # milliseconds on the file's own timeline: what of the film it covers
    # (Publisher). The end is nil when its boxes don't say how long its
    # samples last.
    sig { params(path: T.any(String, Pathname), tracks: T::Array[Track]).returns(T.nilable([ Integer, T.nilable(Integer) ])) }
    def self.video_span_ms(path, tracks) = span_ms(runs(path), tracks)

    # The same, from a fragment's runs already read.
    sig { params(runs: T::Array[Run], tracks: T::Array[Track]).returns(T.nilable([ Integer, T.nilable(Integer) ])) }
    def self.span_ms(runs, tracks)
      video = tracks.find(&:video)
      run = video && runs.find { |candidate| candidate.track_id == video.id && candidate.samples.positive? }
      return nil if video.nil? || run.nil?

      start = run.decode_time + run.first_offset - video.media_time
      default = run.default_duration || video.default_duration
      duration = if run.untimed_samples.zero? then run.timed_duration
      elsif default then run.timed_duration + (default * run.untimed_samples)
      end
      to_ms = ->(time) { (time * 1000.0 / video.timescale).round }
      [ to_ms.call(start), duration && to_ms.call(start + duration) ]
    end

    sig { params(data: String, from: Integer, to: Integer).returns(T.nilable(Track)) }
    def self.track(data, from, to)
      id = T.let(nil, T.nilable(Integer))
      timescale = T.let(nil, T.nilable(Integer))
      handler = T.let(nil, T.nilable(String))
      media_time = 0
      each_box(data, from, to, %w[tkhd mdia edts]) do |type, at, finish|
        case type
        when "tkhd" then id = uint(data, at + (data.getbyte(at) == 1 ? 20 : 12), 4)
        when "edts"
          each_box(data, at, finish, %w[elst]) { |_, elst_at, _| media_time = edit_start(data, elst_at) }
        when "mdia"
          each_box(data, at, finish, %w[mdhd hdlr]) do |inner, inner_at, _|
            timescale = uint(data, inner_at + (data.getbyte(inner_at) == 1 ? 20 : 12), 4) if inner == "mdhd"
            handler = data.byteslice(inner_at + 8, 4) if inner == "hdlr"
          end
        end
      end
      return nil if id.nil? || timescale.nil? || timescale.zero?

      video = handler == "vide"
      Track.new(id: id, video: video, timescale: timescale, media_time: media_time, config: video ? config(data, from, to) : nil)
    end
    private_class_method :track

    # The decoder configuration box of a picture track's first sample
    # entry, whole: trak › mdia › minf › stbl › stsd › avc1 (or hvc1, …) ›
    # avcC (or hvcC, …). A visual sample entry's own fields are 78 bytes.
    CONFIG_BOXES = %w[avcC hvcC av1C vpcC].freeze
    VISUAL_ENTRY = 78

    sig { params(data: String, from: Integer, to: Integer).returns(T.nilable(String)) }
    def self.config(data, from, to)
      found = T.let(nil, T.nilable(String))
      each_box(data, from, to, %w[mdia]) do |_, mdia_at, mdia_end|
        each_box(data, mdia_at, mdia_end, %w[minf]) do |_, minf_at, minf_end|
          each_box(data, minf_at, minf_end, %w[stbl]) do |_, stbl_at, stbl_end|
            each_box(data, stbl_at, stbl_end, %w[stsd]) do |_, stsd_at, stsd_end|
              # Version/flags and an entry count, then the first entry.
              entry_at = stsd_at + 8
              entry_end = [ entry_at + uint(data, entry_at, 4), stsd_end ].min
              each_box(data, entry_at + 8 + VISUAL_ENTRY, entry_end, CONFIG_BOXES) do |type, box_at, box_end|
                found ||= "#{type}:#{data.byteslice(box_at, box_end - box_at).to_s.unpack1('H*')}"
              end
            end
          end
        end
      end
      found
    end
    private_class_method :config

    # The media time of the first edit that plays anything (an empty edit
    # has -1).
    sig { params(data: String, at: Integer).returns(Integer) }
    def self.edit_start(data, at)
      long = data.getbyte(at) == 1
      count = uint(data, at + 4, 4)
      offset = at + 8
      count.times do
        time = long ? int(data, offset + 8, 8) : int(data, offset + 4, 4)
        return time if time >= 0

        offset += long ? 20 : 12
      end
      0
    end
    private_class_method :edit_start

    sig { params(data: String, from: Integer, to: Integer).returns(T.nilable(Run)) }
    def self.run(data, from, to)
      id = T.let(nil, T.nilable(Integer))
      decode_time = T.let(nil, T.nilable(Integer))
      samples = 0
      first_offset = T.let(nil, T.nilable(Integer))
      default_duration = T.let(nil, T.nilable(Integer))
      # Durations the truns gave, and how many samples they left to the default.
      given = 0
      defaulted = 0
      each_box(data, from, to, %w[tfhd tfdt trun]) do |type, at, finish|
        case type
        when "tfhd"
          id = uint(data, at + 4, 4)
          default_duration = tfhd_default_duration(data, at)
        when "tfdt" then decode_time = data.getbyte(at) == 1 ? uint(data, at + 4, 8) : uint(data, at + 4, 4)
        when "trun"
          flags = uint(data, at, 4) & 0xffffff
          count = uint(data, at + 4, 4)
          first_offset ||= first_composition_offset(data, at, flags) if count.positive?
          samples += count
          durations = sample_durations(data, at, finish, flags, count)
          if durations
            given += durations
          else
            defaulted += count
          end
        end
      end
      return nil if id.nil? || decode_time.nil?

      Run.new(track_id: id, decode_time: decode_time, first_offset: first_offset || 0, samples: samples,
        timed_duration: given, untimed_samples: defaulted, default_duration: default_duration)
    end
    private_class_method :run

    # A tfhd's default sample duration, when it carries one.
    sig { params(data: String, at: Integer).returns(T.nilable(Integer)) }
    def self.tfhd_default_duration(data, at)
      flags = uint(data, at, 4) & 0xffffff
      return nil if flags.nobits?(0x8)

      offset = at + 8
      offset += 8 if flags.anybits?(0x1)
      offset += 4 if flags.anybits?(0x2)
      uint(data, offset, 4)
    end
    private_class_method :tfhd_default_duration

    # The sum of a trun's per-sample durations; nil when it gives none (its
    # samples take the default), or when its table runs past what was read.
    sig { params(data: String, at: Integer, finish: Integer, flags: Integer, count: Integer).returns(T.nilable(Integer)) }
    def self.sample_durations(data, at, finish, flags, count)
      return nil if flags.nobits?(0x100)

      offset = at + 8
      offset += 4 if flags.anybits?(0x1)
      offset += 4 if flags.anybits?(0x4)
      stride = 4 * [ 0x100, 0x200, 0x400, 0x800 ].count { |bit| flags.anybits?(bit) }
      return nil if offset + (stride * count) > finish

      (0...count).sum { |index| uint(data, offset + (stride * index), 4) }
    end
    private_class_method :sample_durations

    sig { params(data: String, at: Integer, flags: Integer).returns(Integer) }
    def self.first_composition_offset(data, at, flags)
      return 0 if flags.nobits?(0x800)

      offset = at + 8
      offset += 4 if flags.anybits?(0x1)
      offset += 4 if flags.anybits?(0x4)
      offset += 4 if flags.anybits?(0x100)
      offset += 4 if flags.anybits?(0x200)
      offset += 4 if flags.anybits?(0x400)
      int(data, offset, 4)
    end
    private_class_method :first_composition_offset

    # The first top-level box of a type in a file's head (its first HEAD
    # bytes, as reading them all would see it), read alone: each box
    # before it is stepped over by its header, so the media isn't read.
    # Empty when there's none.
    sig { params(path: T.any(String, Pathname), wanted: String).returns(String) }
    def self.first_box(path, wanted)
      File.open(path.to_s, "rb") do |file|
        to = [ file.size, HEAD ].min
        offset = 0
        while offset + 8 <= to
          file.seek(offset)
          header = file.read([ 16, to - offset ].min).to_s
          size = uint(header, 0, 4)
          type = header.byteslice(4, 4).to_s
          length = 8
          if size == 1
            size = uint(header, 8, 8)
            length = 16
          end
          size = to - offset if size.zero?
          break if size < length

          if type == wanted
            file.seek(offset)
            return file.read([ offset + size, to ].min - offset).to_s
          end
          offset += size
        end
      end
      ""
    end
    private_class_method :first_box

    # Each box of the wanted types between two offsets: its type, and where
    # its payload starts and ends.
    sig do
      params(data: String, from: Integer, to: Integer, wanted: T::Array[String],
        block: T.proc.params(type: String, at: Integer, finish: Integer).void).void
    end
    def self.each_box(data, from, to, wanted, &block)
      offset = from
      while offset + 8 <= to
        size = uint(data, offset, 4)
        type = data.byteslice(offset + 4, 4).to_s
        header = 8
        if size == 1
          size = uint(data, offset + 8, 8)
          header = 16
        end
        size = to - offset if size.zero?
        break if size < header

        # A box running past what was read (the media itself) is the last.
        block.call(type, offset + header, [ offset + size, to ].min) if wanted.include?(type)
        offset += size
      end
    end
    private_class_method :each_box

    sig { params(data: String, at: Integer, bytes: Integer).returns(Integer) }
    def self.uint(data, at, bytes)
      slice = data.byteslice(at, bytes)
      raise Unreadable, "cut short at byte #{at}" if slice.nil? || slice.bytesize < bytes

      slice.unpack1(bytes == 8 ? "Q>" : "N")
    end
    private_class_method :uint

    sig { params(data: String, at: Integer, bytes: Integer).returns(Integer) }
    def self.int(data, at, bytes)
      slice = data.byteslice(at, bytes)
      raise Unreadable, "cut short at byte #{at}" if slice.nil? || slice.bytesize < bytes

      slice.unpack1(bytes == 8 ? "q>" : "l>")
    end
    private_class_method :int
  end
end
