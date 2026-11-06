# typed: strict
# frozen_string_literal: true

module Playback
  # Web hears the moment a fragment is ready (docs/PERF_PROPOSAL.md › P11):
  # the transcoder, or an upload from a remote one, sends NOTIFY
  # stream_ready, and one thread per process listens and wakes the requests
  # waiting on that session. A waiting request used to look for its file
  # every 25 ms; now it sleeps until told, looking again at most every
  # FALLBACK in case a notification is ever lost.
  #
  # Not in specs, where no transcoder announces anything and each spec's
  # transaction would hide it anyway: there a wait is the old short sleep.
  module Readiness
    extend T::Sig

    CHANNEL = "stream_ready"
    # The longest a waiting request sleeps between looks, notified or not.
    FALLBACK = 0.25
    # A wait with nobody listening: the old poll.
    POLL = 0.025

    LOCK = Mutex.new
    CHANGED = ConditionVariable.new
    GENERATIONS = T.let({}, T::Hash[String, Integer])
    STATE = T.let({ listener: nil, listening: false }, T::Hash[Symbol, T.untyped])

    # A mark to wait past: read it before looking for the file, so a
    # fragment that lands in between still wakes the wait.
    sig { params(session_id: String, variant: Integer).returns(Integer) }
    def self.generation(session_id, variant) = LOCK.synchronize { GENERATIONS.fetch(key(session_id, variant), 0) }

    # Sleeps until something of this session's is announced after the
    # mark, or FALLBACK passes.
    sig { params(session_id: String, variant: Integer, mark: Integer).void }
    def self.wait(session_id, variant, mark)
      listen
      unless STATE[:listening]
        sleep POLL
        return
      end

      name = key(session_id, variant)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + FALLBACK
      LOCK.synchronize do
        while GENERATIONS.fetch(name, 0) == mark
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          break if remaining <= 0

          CHANGED.wait(LOCK, remaining)
        end
      end
    end

    # What the transcoder (or an upload) announced: "<session>:<variant>:<gop>".
    sig { params(payload: String).void }
    def self.heard(payload)
      session_id, variant = payload.split(":", 3)
      return if session_id.blank?

      LOCK.synchronize do
        name = key(session_id.to_s, variant.to_i)
        GENERATIONS[name] = GENERATIONS.fetch(name, 0) + 1
        CHANGED.broadcast
      end
    end

    # Forget what's long over, so the counters don't grow with every session.
    sig { void }
    def self.prune
      LOCK.synchronize { GENERATIONS.clear if GENERATIONS.size > 10_000 }
    end

    sig { returns(T::Boolean) }
    def self.enabled? = !Rails.env.test?

    # Starts this process's listener, once (in each Puma worker, after the fork).
    sig { void }
    def self.listen
      return unless enabled?
      return if STATE[:listener]&.alive?

      LOCK.synchronize do
        next if STATE[:listener]&.alive?

        STATE[:listener] = Thread.new { run_listener }
      end
    end

    sig { void }
    def self.run_listener
      loop do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          raw = connection.raw_connection
          raw.async_exec("LISTEN #{CHANNEL}")
          STATE[:listening] = true
          loop do
            raw.wait_for_notify(30) { |_channel, _pid, payload| heard(payload.to_s) }
            prune
          end
        end
      rescue StandardError => e
        STATE[:listening] = false
        Rails.logger.warn("[readiness] listener lost: #{e.class}: #{e.message}")
        sleep 1
      end
    end
    private_class_method :run_listener

    sig { params(session_id: String, variant: Integer).returns(String) }
    def self.key(session_id, variant) = "#{session_id}:#{variant}"
    private_class_method :key
  end
end
