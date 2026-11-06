# typed: strict
# frozen_string_literal: true

module Playback
  # What a stream has sent (PROPOSAL §7.4), added up in memory and written
  # with the session's periodic last_seen_at touch rather than as an UPDATE
  # per segment (docs/PERF_PROPOSAL.md › P13). Per process; whatever a
  # process holds when it exits is written then.
  module BytesSent
    extend T::Sig

    PENDING = T.let({}, T::Hash[String, Integer])
    LOCK = Mutex.new

    sig { params(session_id: String, bytes: Integer).void }
    def self.add(session_id, bytes)
      LOCK.synchronize { PENDING[session_id] = PENDING.fetch(session_id, 0) + bytes }
    end

    # Write what this process holds for one session, or for every one.
    sig { params(session_id: T.nilable(String)).void }
    def self.flush(session_id = nil)
      held = LOCK.synchronize do
        if session_id
          bytes = PENDING.delete(session_id)
          bytes ? { session_id => bytes } : {}
        else
          PENDING.dup.tap { PENDING.clear }
        end
      end
      held.each do |id, bytes|
        PlaybackSession.update_counters(id, bytes_sent: bytes) # rubocop:disable Rails/SkipsModelValidations
      end
    end

    # What a request for a file this size sends: the range asked for, else
    # the whole file.
    sig { params(range: String, size: Integer).returns(Integer) }
    def self.of_request(range, size)
      asked = range.match(/\Abytes=(\d*)-(\d*)\z/)
      return size if asked.nil?

      first = asked[1].to_s.empty? ? size - asked[2].to_i : asked[1].to_i
      last = asked[1].to_s.empty? || asked[2].to_s.empty? ? size - 1 : [ asked[2].to_i, size - 1 ].min
      [ last - first + 1, 0 ].max
    end
  end
end

at_exit do
  Playback::BytesSent.flush
rescue StandardError
  nil
end
