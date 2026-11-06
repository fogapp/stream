# typed: strict
# frozen_string_literal: true

# Plays one file of each format the library has, every way the server can
# (Playback::Trial), so a format that can't be converted or repackaged is
# found before a viewer meets it. On
# the heavy queue, which waits while anyone watches; a few formats a run,
# and again from the top when Stream or its ffmpeg changes. What it finds
# is recorded as the server's (Playability, client class "server"), which
# every kind of client then learns from (Playback::Learned).
class PlayabilitySweepJob < ApplicationJob
  extend T::Sig

  JOB_KEY = "playability_sweep"
  # Formats tried in one run: each is a few short ffmpeg runs.
  PER_RUN = 6
  # A format no way of playing could be tried on leaves no row to say it
  # had its go: left alone this long, rather than taking a place every run.
  UNANSWERED_FOR = T.let(7.days, ActiveSupport::Duration)

  queue_as :heavy
  limits_concurrency to: 1, key: ->(_job_run_id = nil) { "playability_sweep" }, duration: 6.hours

  sig { params(job_run_id: T.nilable(String)).void }
  def perform(job_run_id = nil)
    track_run(job_key: JOB_KEY, job_run_id: job_run_id) do
      version = self.class.version
      tried = Household.find_each.sum { |household| sweep(household, version) }
      tried.zero? ? "every format tried with this version" : "#{tried} format#{tried == 1 ? '' : 's'} tried"
    end
  end

  # What a result was found with: a new one tries everything again.
  sig { returns(String) }
  def self.version = "#{StreamVersion.short_sha}|#{ToolRunner.version('ffmpeg')}"

  private

  # Every format tried with this version and nothing probed since: the
  # library isn't read again until a file is.
  sig { params(household: Household, version: String).returns(Integer) }
  def sweep(household, version)
    probed = MediaFile.unscoped.where(household_id: household.id, state: MediaFile::State::Probed.serialize)
    latest = probed.maximum(:probed_at).to_i
    done = [ "playability_sweep:done", household.id, version ]
    return 0 if Rails.cache.read(done) == latest

    swept = Playability.unscoped.where(household_id: household.id, client_class: Playback::Learned::SERVER, version: version)
      .distinct.pluck(:format_signature).to_set
    samples = T.let({}, T::Hash[String, String])
    # A format is its container and streams: the rest of the row (its
    # keyframes, the raw probe) is read only for the samples tried.
    probed.select(:id, :container).includes(:media_streams).find_each do |file|
      next if file.primary_video.nil?

      signature = Playback::Learned.signature(file)
      samples[signature] ||= file.id unless swept.include?(signature) || Rails.cache.exist?(unanswered(household, version, signature))
    end
    Rails.cache.write(done, latest) if samples.empty?
    samples.to_a.first(PER_RUN).each do |signature, id|
      file = MediaFile.unscoped.find_by(id: id)
      next if file.nil? || try(file, version) != :unanswered

      Rails.cache.write(unanswered(household, version, signature), true, expires_in: UNANSWERED_FOR)
    end
    [ samples.size, PER_RUN ].min
  end

  sig { params(household: Household, version: String, signature: String).returns(T::Array[String]) }
  def unanswered(household, version, signature) = [ "playability_sweep:unanswered", household.id, version, signature ]

  # :tried, :unanswered when nothing could be tried on it, or :busy when
  # it's being read and a later run will have it.
  sig { params(file: MediaFile, version: String).returns(Symbol) }
  def try(file, version)
    # Unindexed formats (TS, AVI, MPEG) are the risky ones: in the house's
    # idle time, the sample's index is made, so its copies are tried too.
    unless Media::KeyframeIndex.usable?(file) || Media::KeyframeIndex.unavailable?(file) || Media::KeyframeIndex.index_from_container!(file)
      indexed = Media::OnePass.exclusively(file) { Media::KeyframeIndex.scan!(file, hold: HoldHeavyWhileWatchingJob.hold) }
      return :busy if indexed.nil?

      file.reload
    end
    copyable = Media::KeyframeIndex.usable?(file)
    answered = T.let(false, T::Boolean)
    Playback::Trial::RUNGS.each_key do |rung|
      next if !copyable && rung != "video_transcode_software"

      outcome = Playback::Trial.new(file, rung).run
      next if outcome.nil?

      answered = true
      Playback::Learned.tried!(file, rung, outcome, version)
      next if outcome.ok

      Activity.record(source: "playback", event: "playability.failed", severity: Activity::Severity::Warn, subject: file,
        household_id: file.household_id, summary: "#{file.filename} can't be played by #{Playback::Learned::LABELS.fetch(rung).downcase}: " \
                                                  "#{outcome.cause}".truncate(500))
    end
    answered ? :tried : :unanswered
  rescue StandardError => e
    Rails.error.report(e, handled: true, source: "playability_sweep")
    :unanswered
  end
end
