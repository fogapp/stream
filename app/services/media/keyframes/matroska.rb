# typed: strict
# frozen_string_literal: true

module Media
  module Keyframes
    # Keyframe times from a Matroska/WebM file's own Cues element (PROPOSAL
    # §5.3): the SeekHead near the start says where the Cues are, and the
    # Cues list each video keyframe's timestamp. A few KB read however big
    # the file, instead of every packet in it.
    #
    # Returns nil when the file doesn't carry what's needed (no SeekHead
    # entry for Cues, no video track, cues for another track): the packet
    # scan is the fallback.
    class Matroska
      extend T::Sig

      SEGMENT = 0x18538067
      SEEK_HEAD = 0x114D9B74
      SEEK = 0x4DBB
      SEEK_ID = 0x53AB
      SEEK_POSITION = 0x53AC
      INFO = 0x1549A966
      TIMESTAMP_SCALE = 0x2AD7B1
      TRACKS = 0x1654AE6B
      TRACK_ENTRY = 0xAE
      TRACK_NUMBER = 0xD7
      TRACK_TYPE = 0x83
      CUES = 0x1C53BB6B
      CUE_POINT = 0xBB
      CUE_TIME = 0xB3
      CUE_TRACK_POSITIONS = 0xB7
      CUE_TRACK = 0xF7

      # Cues for a long film run to a few hundred KB; anything bigger than
      # this isn't a Cues element we want to hold in memory.
      MAX_ELEMENT = T.let(16 * 1024 * 1024, Integer)
      HEAD_BYTES = T.let(256 * 1024, Integer)

      Element = T.type_alias { [ Integer, Integer, Integer ] } # id, data offset, data size

      sig { params(path: String).void }
      def initialize(path)
        @path = path
      end

      sig { returns(T.nilable(T::Array[Integer])) }
      def keyframes_ms
        File.open(@path, "rb") do |file|
          @file = T.let(file, T.nilable(File))
          segment = find_segment
          return nil if segment.nil?

          seeks = seek_positions(segment)
          info = seeks[INFO] && read_element(segment + T.must(seeks[INFO]))
          tracks = seeks[TRACKS] && read_element(segment + T.must(seeks[TRACKS]))
          cues = seeks[CUES] && read_element(segment + T.must(seeks[CUES]))
          return nil if tracks.nil? || cues.nil?

          scale = info ? (child_uint(info, TIMESTAMP_SCALE) || 1_000_000) : 1_000_000
          video = video_track(tracks)
          return nil if video.nil?

          times = cue_times(cues, video)
          times.empty? ? nil : times.map { |time| (time * scale / 1_000_000.0).round }.uniq.sort
        end
      rescue SystemCallError, EOFError, RangeError
        nil
      end

      private

      sig { returns(File) }
      def file = T.must(@file)

      # The byte offset where the Segment's data starts: SeekHead positions
      # are relative to it.
      sig { returns(T.nilable(Integer)) }
      def find_segment
        file.seek(0)
        head = file.read(HEAD_BYTES).to_s
        offset = 0
        2.times do
          id, id_len = read_id(head, offset)
          size, size_len = read_size(head, offset + id_len)
          return offset + id_len + size_len if id == SEGMENT
          return nil if size.nil?

          offset += id_len + size_len + size
        end
        nil
      end

      sig { params(segment: Integer).returns(T::Hash[Integer, Integer]) }
      def seek_positions(segment)
        file.seek(segment)
        head = file.read(HEAD_BYTES).to_s
        positions = {}
        each_child(head, 0, head.bytesize) do |id, data, size|
          next unless id == SEEK_HEAD

          each_child(head, data, size) do |seek_id, seek_data, seek_size|
            next unless seek_id == SEEK

            target = T.let(nil, T.nilable(Integer))
            position = T.let(nil, T.nilable(Integer))
            each_child(head, seek_data, seek_size) do |field, field_data, field_size|
              target = uint(head.byteslice(field_data, field_size).to_s) if field == SEEK_ID
              position = uint(head.byteslice(field_data, field_size).to_s) if field == SEEK_POSITION
            end
            positions[target] = position if target && position
          end
          break
        end
        positions
      end

      # The whole element at an absolute offset, as a byte string of its data.
      sig { params(offset: Integer).returns(T.nilable(String)) }
      def read_element(offset)
        file.seek(offset)
        header = file.read(12).to_s
        _id, id_len = read_id(header, 0)
        size, size_len = read_size(header, id_len)
        return nil if size.nil? || size > MAX_ELEMENT

        file.seek(offset + id_len + size_len)
        data = file.read(size).to_s
        data.bytesize == size ? data : nil
      end

      sig { params(tracks: String).returns(T.nilable(Integer)) }
      def video_track(tracks)
        each_child(tracks, 0, tracks.bytesize) do |id, data, size|
          next unless id == TRACK_ENTRY

          entry = T.must(tracks.byteslice(data, size))
          return child_uint(entry, TRACK_NUMBER) if child_uint(entry, TRACK_TYPE) == 1
        end
        nil
      end

      sig { params(cues: String, video: Integer).returns(T::Array[Integer]) }
      def cue_times(cues, video)
        times = []
        each_child(cues, 0, cues.bytesize) do |id, data, size|
          next unless id == CUE_POINT

          point = T.must(cues.byteslice(data, size))
          time = child_uint(point, CUE_TIME)
          on_video = T.let(false, T::Boolean)
          each_child(point, 0, point.bytesize) do |child, child_data, child_size|
            next unless child == CUE_TRACK_POSITIONS

            positions = T.must(point.byteslice(child_data, child_size))
            on_video = true if child_uint(positions, CUE_TRACK) == video
          end
          times << time if time && on_video
        end
        times
      end

      sig { params(data: String, id: Integer).returns(T.nilable(Integer)) }
      def child_uint(data, id)
        each_child(data, 0, data.bytesize) do |child, child_data, child_size|
          return uint(data.byteslice(child_data, child_size).to_s) if child == id
        end
        nil
      end

      sig do
        params(data: String, start: Integer, length: Integer,
          block: T.proc.params(id: Integer, data_offset: Integer, size: Integer).void).void
      end
      def each_child(data, start, length, &block)
        offset = start
        finish = [ start + length, data.bytesize ].min
        while offset < finish
          id, id_len = read_id(data, offset)
          size, size_len = read_size(data, offset + id_len)
          break if size.nil? || id_len.zero? || size_len.zero?

          data_offset = offset + id_len + size_len
          break if data_offset + size > finish

          block.call(id, data_offset, size)
          offset = data_offset + size
        end
      end

      # EBML IDs keep their length-marker bits.
      sig { params(data: String, offset: Integer).returns([ Integer, Integer ]) }
      def read_id(data, offset)
        first = data.getbyte(offset)
        return [ 0, 0 ] if first.nil? || first.zero?

        length = 8 - Math.log2(first).floor
        return [ 0, 0 ] if length > 4

        [ uint(data.byteslice(offset, length).to_s), length ]
      end

      # Sizes drop the marker; all ones means "unknown".
      sig { params(data: String, offset: Integer).returns([ T.nilable(Integer), Integer ]) }
      def read_size(data, offset)
        first = data.getbyte(offset)
        return [ nil, 0 ] if first.nil? || first.zero?

        length = 8 - Math.log2(first).floor
        raw = uint(data.byteslice(offset, length).to_s)
        value = raw & ((1 << (7 * length)) - 1)
        [ value == (1 << (7 * length)) - 1 ? nil : value, length ]
      end

      sig { params(bytes: String).returns(Integer) }
      def uint(bytes) = bytes.bytes.reduce(0) { |acc, byte| (acc << 8) | byte }
    end
  end
end
