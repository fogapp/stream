# typed: strict
# frozen_string_literal: true

module Media
  module Keyframes
    # Keyframe times from an MP4/MOV file's own sample tables (PROPOSAL
    # §5.3): stss names the sync samples, stts gives every sample's decode
    # time, ctts its composition offset, and the edit list says where
    # presentation starts. Only the moov box is read — usually a few MB even
    # for a long film — wherever in the file it sits.
    #
    # Returns nil for anything it can't answer exactly (fragmented MP4, no
    # stss, no video track): the packet scan is the fallback.
    class Mp4
      extend T::Sig

      CONTAINERS = T.let(%w[moov trak mdia minf stbl edts].to_set.freeze, T::Set[String])
      MAX_MOOV = T.let(64 * 1024 * 1024, Integer)

      Box = T.type_alias { [ String, Integer, Integer ] } # type, data offset, data size

      sig { params(path: String).void }
      def initialize(path)
        @path = path
      end

      sig { returns(T.nilable(T::Array[Integer])) }
      def keyframes_ms
        moov = read_moov
        return nil if moov.nil?

        boxes(moov, 0, moov.bytesize).each do |type, data, size|
          next unless type == "trak"

          track = T.must(moov.byteslice(data, size))
          times = video_keyframes(track)
          return times if times
        end
        nil
      rescue SystemCallError, EOFError, RangeError
        nil
      end

      private

      sig { returns(T.nilable(String)) }
      def read_moov
        File.open(@path, "rb") do |file|
          offset = 0
          size_on_disk = file.size
          while offset + 8 <= size_on_disk
            file.seek(offset)
            header = file.read(16).to_s
            size = header.byteslice(0, 4).to_s.unpack1("N").to_i
            type = header.byteslice(4, 4).to_s
            header_len = 8
            if size == 1
              size = header.byteslice(8, 8).to_s.unpack1("Q>").to_i
              header_len = 16
            elsif size.zero?
              size = size_on_disk - offset
            end
            return nil if size < header_len
            # A fragmented file's sample tables are empty; its keyframes
            # live in the fragments.
            return nil if type == "moof"

            if type == "moov"
              return nil if size > MAX_MOOV

              file.seek(offset + header_len)
              return file.read(size - header_len).to_s
            end
            offset += size
          end
          nil
        end
      end

      sig { params(track: String).returns(T.nilable(T::Array[Integer])) }
      def video_keyframes(track)
        tables = {}
        collect(track, 0, track.bytesize, tables)
        return nil unless tables["hdlr"]&.byteslice(8, 4) == "vide"

        timescale = mdhd_timescale(tables["mdhd"])
        stss = tables["stss"]
        stts = tables["stts"]
        return nil if timescale.nil? || timescale.zero? || stss.nil? || stts.nil?

        sync = T.let(full_box_entries(stss).map { |entry| entry.unpack1("N").to_i }, T::Array[Integer])
        last = sync.max
        return nil if last.nil?

        decode = decode_times(stts, last)
        offsets = composition_offsets(tables["ctts"], last)
        shift = edit_shift(tables["elst"])
        sync.filter_map do |number|
          dts = decode[number - 1]
          next nil if dts.nil?

          ((dts + offsets.fetch(number - 1, 0) - shift) * 1000.0 / timescale).round
        end.uniq.sort
      end

      # Flattens the boxes under a trak that the calculation needs.
      sig { params(data: String, start: Integer, length: Integer, tables: T::Hash[String, String]).void }
      def collect(data, start, length, tables)
        boxes(data, start, length).each do |type, offset, size|
          if CONTAINERS.include?(type)
            collect(data, offset, size, tables)
          elsif %w[hdlr mdhd stss stts ctts elst].include?(type)
            tables[type] ||= T.must(data.byteslice(offset, size))
          end
        end
      end

      sig { params(data: String, start: Integer, length: Integer).returns(T::Array[Box]) }
      def boxes(data, start, length)
        found = []
        offset = start
        finish = start + length
        while offset + 8 <= finish
          size = data.byteslice(offset, 4).to_s.unpack1("N").to_i
          type = data.byteslice(offset + 4, 4).to_s
          header = 8
          if size == 1
            size = data.byteslice(offset + 8, 8).to_s.unpack1("Q>").to_i
            header = 16
          elsif size.zero?
            size = finish - offset
          end
          break if size < header || offset + size > finish

          found << [ type, offset + header, size - header ]
          offset += size
        end
        found
      end

      sig { params(mdhd: T.nilable(String)).returns(T.nilable(Integer)) }
      def mdhd_timescale(mdhd)
        return nil if mdhd.nil?

        version = mdhd.getbyte(0)
        mdhd.byteslice(version == 1 ? 20 : 12, 4).to_s.unpack1("N")&.to_i
      end

      # A full box's entry list: version/flags, a count, then fixed-size entries.
      sig { params(box: String, entry_size: Integer).returns(T::Array[String]) }
      def full_box_entries(box, entry_size = 4)
        count = box.byteslice(4, 4).to_s.unpack1("N").to_i
        Array.new(count) { |i| box.byteslice(8 + (i * entry_size), entry_size).to_s }
      end

      sig { params(stts: String, needed: Integer).returns(T::Array[Integer]) }
      def decode_times(stts, needed)
        times = []
        clock = 0
        full_box_entries(stts, 8).each do |entry|
          count, delta = entry.unpack("NN").map(&:to_i)
          T.must(count).times do
            times << clock
            clock += T.must(delta)
            return times if times.size >= needed
          end
        end
        times
      end

      # Version 1 offsets are signed; version 0 ones are too in practice
      # (ffmpeg and others write negative offsets there), so read signed.
      sig { params(ctts: T.nilable(String), needed: Integer).returns(T::Array[Integer]) }
      def composition_offsets(ctts, needed)
        return [] if ctts.nil?

        offsets = []
        full_box_entries(ctts, 8).each do |entry|
          count = entry.byteslice(0, 4).to_s.unpack1("N").to_i
          offset = entry.byteslice(4, 4).to_s.unpack1("l>").to_i
          count.times do
            offsets << offset
            return offsets if offsets.size >= needed
          end
        end
        offsets
      end

      # Where presentation starts in media time: the first non-empty edit's
      # media_time, which ffmpeg subtracts from every timestamp.
      sig { params(elst: T.nilable(String)).returns(Integer) }
      def edit_shift(elst)
        return 0 if elst.nil?

        version = elst.getbyte(0)
        entry_size = version == 1 ? 20 : 12
        full_box_entries(elst, entry_size).each do |entry|
          media_time = version == 1 ? entry.byteslice(8, 8).to_s.unpack1("q>").to_i : entry.byteslice(4, 4).to_s.unpack1("l>").to_i
          return media_time unless media_time == -1
        end
        0
      end
    end
  end
end
