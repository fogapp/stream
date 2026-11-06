# typed: strict
# frozen_string_literal: true

module Playback
  # One poll from a remote transcoder's worker (TranscodeNode): what it
  # finished, what it's still running and how far along, answered with the
  # runs to start and the runs to stop. A few times a second while it has
  # work, so a seek reaches it in well under a second.
  module NodeLink
    extend T::Sig

    # A handed-out run the worker hasn't mentioned in this long is lost.
    GRACE = T.let(5.seconds, ActiveSupport::Duration)
    POLL_MS = 250
    # How stale last_seen_at may be before a poll writes it: well inside
    # TranscodeNode's window for calling a node online.
    SEEN_EVERY = T.let(5.seconds, ActiveSupport::Duration)

    # A run as much as a poll needs to know of it.
    class LiveRun < T::Struct
      const :id, String
      const :state, String
      const :started_at, T.nilable(ActiveSupport::TimeWithZone)
    end

    class Exited < T::Struct
      const :id, String
      const :status, T.nilable(Integer)
      const :log, T.nilable(String)
    end

    class Report < T::Struct
      const :hello, T.nilable(T::Hash[String, T.untyped])
      const :running, T::Array[String]
      const :exited, T::Array[Exited]
      const :progress, T::Hash[String, Float]
    end

    sig { params(raw: T::Hash[String, T.untyped]).returns(Report) }
    def self.parse(raw)
      Report.new(
        hello: raw["hello"].is_a?(Hash) ? raw["hello"] : nil,
        running: Array(raw["running"]).map(&:to_s).first(64),
        exited: Array(raw["exited"]).first(64).filter_map do |entry|
          next unless entry.is_a?(Hash)

          Exited.new(id: entry["id"].to_s, status: entry["status"].nil? ? nil : entry["status"].to_i, log: entry["log"]&.to_s&.last(2000))
        end,
        progress: (raw["progress"].is_a?(Hash) ? raw["progress"] : {}).to_h { |id, seconds| [ id.to_s, seconds.to_f ] }
      )
    end

    # The busiest request Stream has: around the clock, whether anything is
    # running or not. The node's row is written when something about it
    # changed or `online?` needs it, and the runs are looked at once, with
    # only the rows that have to change loaded whole.
    sig { params(node: TranscodeNode, report: Report).returns(T::Hash[Symbol, T.untyped]) }
    def self.poll(node, report)
      seen = node.last_seen_at
      node.last_seen_at = Time.current if seen.nil? || seen < SEEN_EVERY.ago
      hello = report.hello
      introduce(node, hello) if hello
      node.save! if node.changed?

      runs = node.transcode_runs
      take_exits(runs, report.exited)
      report.progress.each do |id, seconds|
        runs.live.where(id: id).update_all(progress_seconds: seconds, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      end
      running = report.running.to_set
      live = runs.live.pluck(:id, :state, :started_at).map { |id, state, started_at| LiveRun.new(id: id, state: state, started_at: started_at) }

      handed_out = live.select { |run| run.state == TranscodeRun::State::Running.serialize }
      lost = handed_out.select { |run| !running.include?(run.id) && run.started_at&.<(GRACE.ago) }.map(&:id)
      exit_runs(runs, lost, "#{node.name} lost track of this run", failure: TranscodeRun::Failure::Lost) if lost.any?

      stop, gone = live.select { |run| run.state == TranscodeRun::State::Stopping.serialize }.map(&:id).partition { |id| running.include?(id) }
      exit_runs(runs, gone, nil) if gone.any?
      # Still running there, but not live here — marked lost, or from before
      # the transcoder restarted: stopped, rather than converting the rest of
      # a film nobody will see.
      known = live.to_set(&:id)
      orphans = running.to_a.reject { |id| known.include?(id) }

      pending = live.select { |run| run.state == TranscodeRun::State::Pending.serialize }.map(&:id)
      start = node.enabled && pending.any? ? runs.where(id: pending).order(:created_at).to_a : []
      start.each { |run| run.update!(state: TranscodeRun::State::Running.serialize, started_at: Time.current) }
      {
        start: start.map { |run| { id: run.id, argv: run.argv, kind: run.optimized_version_id ? "optimize" : "session" } },
        stop: stop + orphans, poll_ms: POLL_MS
      }
    end

    sig { params(runs: T.untyped, exited: T::Array[Exited]).void }
    def self.take_exits(runs, exited)
      exited.each do |entry|
        run = runs.live.find_by(id: entry.id)
        next if run.nil?

        run.exited!(entry.status, entry.log)
        finish_fragments(run) if entry.status&.zero?
      end
    end
    private_class_method :take_exits

    sig { params(runs: T.untyped, ids: T::Array[String], log: T.nilable(String), failure: T.nilable(TranscodeRun::Failure)).void }
    def self.exit_runs(runs, ids, log, failure: nil)
      runs.where(id: ids).find_each { |run| run.exited!(nil, log, failure: failure) }
    end
    private_class_method :exit_runs

    # fog's poll as a pool's transcoder (fog-compute/1): the worker's poll,
    # plus the pool's room, which stands in for max_sessions, and runs
    # handed out with their class, outputs and signed upload address —
    # fog's machines hold no token of Stream's.
    sig { params(node: TranscodeNode, report: Report, raw: T::Hash[String, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
    def self.poll_fog(node, report, raw)
      capacity = raw["capacity"].is_a?(Hash) ? raw["capacity"] : {}
      free = raw["free"].is_a?(Hash) ? raw["free"] : {}
      node.max_sessions = capacity["interactive"].to_i.clamp(0, TranscodeNode::FOG_MAX_SESSIONS)
      node.capabilities = node.capabilities.merge("free" => { "interactive" => free["interactive"].to_i, "batch" => free["batch"].to_i },
        "capacity" => { "interactive" => capacity["interactive"].to_i, "batch" => capacity["batch"].to_i })
      answer = poll(node, report)
      answer.merge(start: answer.fetch(:start).map { |run| fog_run(run) })
    end

    sig { params(run: T::Hash[Symbol, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
    def self.fog_run(run)
      token = RunToken.issue(TranscodeRun.find(run.fetch(:id)))
      optimize = run.fetch(:kind) == "optimize"
      run.merge(
        class: optimize ? "batch" : "interactive",
        outputs: optimize ? { final: [ "output.mp4" ] } : { init: [ "init.mp4" ], stream: "gop-*.m4s" },
        upload: "#{Runner::SERVER}/fog/compute/runs/#{token}/files/{name}"
      )
    end
    private_class_method :fog_run

    FRAGMENT = /\A(?:init\.mp4|gop-(\d{1,6})\.m4s)\z/
    MAX_FRAGMENT = T.let(512.megabytes, Integer)

    # A file a run's worker uploaded: a session's GOP fragment or init
    # segment, or an optimized version's whole output. The name is only
    # ever one of those shapes, rebuilt here rather than trusted, and
    # written aside and renamed, so nothing reads half of one. A fragment
    # goes to the run's own staging and is published from there under the
    # GOP it really holds (Publisher), as a run here is. False for anything
    # else, and for a fragment that isn't one of the plan's — which also
    # stops the run, with why on its session.
    sig { params(run: TranscodeRun, name: String, body: T.untyped, size: Integer).returns(T::Boolean) }
    def self.store(run, name, body, size:)
      session = run.playback_session
      version_id = run.optimized_version_id
      match = FRAGMENT.match(name)
      if session && match
        return false if size > MAX_FRAGMENT

        store_fragment(run, session, match[1]&.to_i, body)
      elsif version_id && name == "output.mp4"
        write(OptimizedVersion.partial_path_for(version_id.to_s), body)
        true
      else
        false
      end
    end

    sig { params(run: TranscodeRun, session: PlaybackSession, gop: T.nilable(Integer), body: T.untyped).returns(T::Boolean) }
    def self.store_fragment(run, session, gop, body)
      staging = Cache.staging(session.id, run.id)
      init = staging.join("init.mp4")
      publisher = Publisher.new(session_id: session.id, variant: 0, plan: SegmentPlan.for(session))
      if gop.nil?
        write(init, body)
        publisher.init(init)
        return true
      end

      staged = staging.join("gop-#{gop}.m4s")
      write(staged, body)
      publisher.init(init)
      # Whoever waits on it hears at once (Readiness): when it completed a
      # GOP, which a keyframe inside one doesn't.
      gop = publisher.fragment(staged)
      Signal.ready(session.id, 0, gop) if gop
      true
    rescue Publisher::Mismatch, Fragment::Unreadable, SystemCallError => e
      refuse(run, session, e.message)
      false
    end
    private_class_method :store_fragment

    # A session's run that ran to its end has uploaded everything (its
    # worker reports it only then): the film's last GOP, which nothing
    # after it closes, is published (Publisher#finish).
    sig { params(run: TranscodeRun).void }
    def self.finish_fragments(run)
      session = run.playback_session
      return if session.nil?

      staging = Cache.staging(session.id, run.id)
      init = staging.join("init.mp4")
      return unless init.file?

      publisher = Publisher.new(session_id: session.id, variant: 0, plan: SegmentPlan.for(session))
      publisher.init(init)
      gop = publisher.finish(staging)
      Signal.ready(session.id, 0, gop) if gop
    rescue Publisher::Mismatch, Fragment::Unreadable, SystemCallError => e
      refuse(run, session, e.message) if session
    end
    private_class_method :finish_fragments

    sig { params(target: Pathname, body: T.untyped).void }
    def self.write(target, body)
      FileUtils.mkdir_p(target.dirname)
      temporary = target.sub_ext(".#{SecureRandom.hex(4)}.upload")
      begin
        File.open(temporary, "wb") { |out| IO.copy_stream(body, out) }
        File.rename(temporary, target)
      ensure
        FileUtils.rm_f(temporary)
      end
    end
    private_class_method :write

    # What the run uploaded isn't the stream that was planned: it stops,
    # and the session says why (what a waiting request answers with).
    sig { params(run: TranscodeRun, session: PlaybackSession, reason: String).void }
    def self.refuse(run, session, reason)
      TranscodeRun.where(id: run.id).update_all(failure: TranscodeRun::Failure::Refused.serialize, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      TranscodeRun.where(id: run.id, state: TranscodeRun::State::Running.serialize)
        .update_all(state: TranscodeRun::State::Stopping.serialize, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      session.transcode_failed!("The stream's fragments weren't what was planned: #{reason}")
    end
    private_class_method :refuse

    # What fog says its pool's machines all have, as it introduces the pool.
    sig { params(node: TranscodeNode, hello: T::Hash[String, T.untyped]).void }
    def self.introduce!(node, hello)
      introduce(node, hello)
      node.save!
    end

    # What the worker found on its machine when it started.
    sig { params(node: TranscodeNode, hello: T::Hash[String, T.untyped]).void }
    def self.introduce(node, hello)
      node.encoder = Encoders::Kind.try_deserialize(hello["encoder"].to_s)&.serialize || Encoders::Kind::Software.serialize
      node.capabilities = {
        "hostname" => hello["hostname"].to_s.first(120), "platform" => hello["platform"].to_s.first(120),
        "ffmpeg" => hello["ffmpeg"].to_s.first(200), "worker" => hello["worker"].to_s.first(40),
        "filters" => Array(hello["filters"]).map(&:to_s).grep(/\A\w+\z/).first(1000)
      }
    end
    private_class_method :introduce
  end
end
