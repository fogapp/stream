# typed: strict
# frozen_string_literal: true

module Playback
  # The top of the Playback page: is playback healthy, and is there
  # something to do about it? Four checks, each a verdict, the number
  # behind it, a sentence, what to do, and where on the page to do it —
  # the tab and filters its card opens.
  module Health
    extend T::Sig

    class Status < T::Enum
      include ApplicationEnum
      enums do
        Ok = new("ok")
        # Worth a look.
        Watch = new("watch")
        # Something to do.
        Act = new("act")
      end
    end

    class Key < T::Enum
      include ApplicationEnum
      enums do
        FailedPlays = new("failed_plays")
        LiveConversions = new("live_conversions")
        Startup = new("startup")
        Optimizer = new("optimizer")
        # Cameras and web streams (PROPOSAL §7.8): only when there are some.
        LiveStreams = new("live_streams")
      end
    end

    WEEK = T.let(7.days, ActiveSupport::Duration)
    # More plays than this stalling is worth a look.
    STALL_SHARE = 0.05
    # The targets in PROPOSAL §6.4, for nineteen plays in twenty.
    STARTUP_TARGET_MS = T.let({
      PlaybackSession::Method::Direct => 800, PlaybackSession::Method::Remux => 1500,
      PlaybackSession::Method::VideoTranscode => 3000
    }.freeze, T::Hash[PlaybackSession::Method, Integer])
    # Fewer timed plays than this says nothing about a method's speed.
    STARTUP_SAMPLE = 5
    # A budget this full is worth a look.
    BUDGET_SHARE = 0.9

    class Check < T::Struct
      const :key, Key
      const :status, Status
      const :title, String
      const :metric, String
      const :detail, String
      # What to do, when there's something to do.
      const :action, T.nilable(String)
      # The tab and its filters, as the page's URL takes them — or, for
      # what's managed elsewhere, the page's own `path`.
      const :link, T::Hash[Symbol, T.untyped]
    end

    sig { returns(T::Array[Check]) }
    def self.checks
      since = WEEK.ago
      [ failed_plays(since), live_conversions(since), startup(since), optimizer, live_streams ].compact
    end

    # Plays that ended on an error: a
    # session that failed and carried on a rung down didn't end the play,
    # so it's counted as recovered, not failed. The target is fewer than
    # one play in a hundred.
    TARGET_SHARE = 0.01

    sig { params(since: ActiveSupport::TimeWithZone).returns(Check) }
    def self.failed_plays(since)
      carried_on = PlaybackSession.unscoped.where.not(fallback_from_id: nil).select(:fallback_from_id)
      scope = SessionQuery.new(SessionQuery::Filters.new(from: since)).scope.unscope(:order, :select)
      outcomes = scope.where.not(id: carried_on).group(:outcome).count
      recovered = scope.where(id: carried_on).count
      failed = outcomes.fetch("failed", 0)
      errored = outcomes.fetch("errored", 0)
      stalled = outcomes.fetch("stalled", 0)
      total = outcomes.values.sum
      broken = failed + errored
      share = total.positive? ? broken.to_f / total : 0.0
      parts = []
      parts << "#{count(failed, 'conversion')} failed" if failed.positive?
      parts << "#{count(errored, 'player')} reported an error" if errored.positive?
      parts << "#{stalled} of #{count(total, 'play')} stalled" if stalled.positive?
      status = if share > TARGET_SHARE then Status::Act
      elsif broken.positive? || (total.positive? && stalled.to_f / total > STALL_SHARE) then Status::Watch
      else Status::Ok
      end
      saved = recovered.positive? ? " #{count(recovered, 'play')} that failed carried on another way." : ""
      Check.new(
        key: Key::FailedPlays, status: status, title: "Plays that ended on an error",
        metric: total.positive? ? "#{(share * 100).round(1)}%" : "0",
        detail: if parts.any? then "This week #{parts.to_sentence}#{broken.positive? ? ' (the aim is under 1%)' : ''}.#{saved}"
                elsif total.zero? then "Nothing was played this week."
                else "None of this week's #{count(total, 'play')} ended on an error.#{saved}"
                end,
        action: status == Status::Ok ? nil : "See which ones, and why.",
        link: { tab: "sessions", outcomes: broken.positive? ? %w[failed errored] : %w[stalled], from: since.iso8601 }
      )
    end

    # Video converted live that an optimized version would have spared:
    # anything but HDR tone-mapped for a screen that can't show it, on a
    # file that still has no optimized version ready.
    sig { params(since: ActiveSupport::TimeWithZone).returns(Check) }
    def self.live_conversions(since)
      converted = PlaybackSession.watched.where(method: PlaybackSession::Method::VideoTranscode.serialize)
      this_week = converted.where(started_at: since..)
      plays = this_week.count
      last_week = converted.where(started_at: (since - WEEK)...since).count
      ready = OptimizedVersion.ready.select(:media_file_id)
      avoidable = this_week.where("(decision->'video'->>'tonemap') IS DISTINCT FROM 'true'").where.not(media_file_id: ready)
      spared = avoidable.count
      trend = last_week == plays ? "the same as last week" : "#{last_week} last week"
      Check.new(
        key: Key::LiveConversions, status: spared.positive? ? Status::Watch : Status::Ok, title: "Live conversions",
        metric: plays.to_s,
        detail: if plays.zero?
                  "No video was converted live this week (#{trend})."
                else
                  "#{count(plays, 'play')} converted video live this week (#{trend}); " \
                    "#{spared.zero? ? 'none' : spared} could have played an optimized version."
                end,
        action: spared.positive? ? "Optimize the files converted most." : nil,
        link: { tab: "converting", statuses: %w[none failed], sort: "conversions", direction: "desc" }
      )
    end

    sig { params(since: ActiveSupport::TimeWithZone).returns(Check) }
    def self.startup(since)
      timings = Report.startup(since)
      slow = STARTUP_TARGET_MS.filter_map do |method, target|
        spread = timings.fetch(method.serialize)
        next if spread[:count] < STARTUP_SAMPLE || spread[:p95_ms].nil? || spread[:p95_ms] <= target

        "#{method.label.downcase} takes up to #{seconds(spread[:p95_ms])} (aiming for #{seconds(target)})"
      end
      timed = timings.values.sum { |spread| spread[:count] }
      direct = timings.fetch(PlaybackSession::Method::Direct.serialize)
      typical = timings.values.filter_map { |spread| spread[:median_ms] }.min
      Check.new(
        key: Key::Startup, status: slow.any? ? Status::Watch : Status::Ok, title: "Start-up speed",
        metric: direct[:median_ms] ? seconds(direct[:median_ms]) : (typical ? seconds(typical) : "—"),
        detail: if slow.any? then "For nineteen plays in twenty, #{slow.to_sentence}."
                elsif timed.zero? then "Nothing was timed this week."
                else "Every way of playing starts within its target."
                end,
        action: slow.any? ? "See the slowest starts." : nil,
        link: { tab: "sessions", sort: "startup_ms", direction: "desc", from: since.iso8601 }
      )
    end

    sig { returns(Check) }
    def self.optimizer
      status = OptimizerStatus.current
      state = T.cast(status[:state], OptimizerStatus::State)
      queue = status[:queue]
      budget = status[:budget]
      share = budget[:budget_bytes].positive? ? budget[:used_bytes].to_f / budget[:budget_bytes] : 0.0
      finished = OptimizedVersion.where(finished_at: WEEK.ago..).count
      stuck = queue[:queued].positive? && finished.zero? && OptimizedVersion.queued.where(created_at: ...WEEK.ago).exists?

      verdict, detail, action, link =
        if state == OptimizerStatus::State::NoTranscoder
          [ Status::Act, status[:message], "Start the transcoder.", { tab: "queue" } ]
        elsif queue[:failed].positive?
          [ Status::Act, "#{count(queue[:failed], 'optimized version')} failed. #{status[:message]}", "Retry them, or see why.",
            { tab: "optimized", states: %w[failed] } ]
        elsif share >= BUDGET_SHARE
          [ Status::Watch, "#{(share * 100).round}% of the space for optimized versions is used. #{status[:message]}",
            "Free up space: delete what nobody plays.", { tab: "optimized", states: %w[ready], unplayed_days: 90, sort: "size", direction: "desc" } ]
        elsif stuck
          [ Status::Watch, "Nothing has been optimized in a week, though #{queue[:queued]} are waiting. #{status[:message]}",
            "See the queue.", { tab: "queue" } ]
        else
          [ Status::Ok, "#{count(finished, 'version')} made this week. #{status[:message]}", nil, { tab: "queue" } ]
        end
      Check.new(key: Key::Optimizer, status: verdict, title: "Optimize backlog", metric: queue[:queued].to_s, detail: detail,
        action: action, link: link)
    end

    # Streams that stopped answering: a probe, a relay or the five-minute
    # picture couldn't reach them. nil when the household has none.
    sig { returns(T.nilable(Check)) }
    def self.live_streams
      streams = LiveStream.added.order(:sort_title).to_a
      return nil if streams.empty?

      offline = streams.reject(&:online?)
      Check.new(
        key: Key::LiveStreams, status: offline.any? ? Status::Act : Status::Ok, title: "Live streams",
        metric: "#{streams.size - offline.size}/#{streams.size}",
        detail: if offline.empty? then "Every camera and web stream answered when last asked."
                else "#{offline.map(&:name).to_sentence} #{offline.one? ? "isn't" : "aren't"} answering: #{offline.first&.last_error}"
                end,
        action: offline.any? ? "Check the address, or the camera." : nil,
        # Streams are managed on their library's page: the first one that
        # isn't answering, or the first stream's when all of them are.
        link: { path: "/library/#{(offline.first || streams.first)&.library_id}" }
      )
    end

    sig { params(number: Integer, noun: String).returns(String) }
    def self.count(number, noun) = "#{number} #{number == 1 ? noun : noun.pluralize}"

    sig { params(ms: T.any(Integer, Float)).returns(String) }
    def self.seconds(ms) = ms < 1000 ? "#{ms.round} ms" : "#{(ms / 1000.0).round(1)} s"
  end
end
