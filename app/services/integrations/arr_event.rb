# typed: strict
# frozen_string_literal: true

module Integrations
  # One Sonarr or Radarr webhook delivery, turned into targeted scans
  # (PROPOSAL §5.1). Stream never trusts the payload's account of what
  # changed; it only takes the folders it names and scans them, which finds
  # new files, marks deleted ones missing and follows renames by fingerprint.
  class ArrEvent
    extend T::Sig

    class Outcome < T::Struct
      const :scanned, T::Array[String]
      const :unplaced, T::Array[String]
      const :summary, String
    end

    # Events that change files on disk. Grab, Health and the rest don't.
    FILE_EVENTS = T.let(%w[Download Rename EpisodeFileDelete MovieFileDelete SeriesDelete MovieDelete].to_set.freeze,
      T::Set[String])

    sig { params(webhook: ArrWebhook, payload: T::Hash[String, T.untyped]).void }
    def initialize(webhook, payload)
      @webhook = webhook
      @payload = payload
      @event = T.let(payload["eventType"].to_s, String)
      @source = T.let(payload.key?("series") ? "Sonarr" : (payload.key?("movie") ? "Radarr" : "Unknown"), String)
    end

    sig { returns(Outcome) }
    def call
      outcome =
        if @event == "Test" then Outcome.new(scanned: [], unplaced: [], summary: "Test received from #{@source}")
        elsif FILE_EVENTS.include?(@event) then scan_folders
        else Outcome.new(scanned: [], unplaced: [], summary: "#{@event} ignored: nothing changed on disk")
        end
      @webhook.update!(last_received_at: Time.current, last_source: @source, last_event: @event, last_outcome: outcome.summary)
      record(outcome)
      outcome
    end

    private

    # The folder that holds what changed: the series or movie folder. Scanning
    # the whole folder is cheap and catches everything a rename or upgrade
    # touched.
    sig { returns(T::Array[String]) }
    def remote_folders
      folders = [
        @payload.dig("series", "path"),
        @payload.dig("movie", "folderPath"),
        # Older Radarr and some events name only a file.
        @payload.dig("movieFile", "path")&.then { |path| File.dirname(path.to_s) },
        @payload.dig("episodeFile", "path")&.then { |path| File.dirname(File.dirname(path.to_s)) }
      ]
      folders.compact.map(&:to_s).reject(&:empty?).uniq
    end

    sig { returns(Outcome) }
    def scan_folders
      libraries = Library.unscoped.where(household_id: @webhook.household_id).to_a
      scanned = []
      unplaced = []
      remote_folders.each do |remote|
        local = PathMapping.translate(@webhook.household_id, remote)
        library = libraries.find { |candidate| candidate.roots.any? { |root| Media::SafePath.within?(local, root) } }
        if library.nil?
          unplaced << remote
          next
        end
        # A deleted series' folder is gone; scan its parent so its files are
        # marked missing rather than the scan failing on a missing path.
        target = File.directory?(local) ? local : library.roots.find { |root| Media::SafePath.within?(local, root) }
        ScanLibraryJob.perform_later(library.id, target)
        scanned << local
      end
      summary =
        if unplaced.any?
          "#{@source} #{@event}: no library holds #{unplaced.join(', ')}. Add a path mapping in Settings › Integrations."
        else
          "#{@source} #{@event}: scanning #{scanned.map { |path| File.basename(path) }.join(', ')}"
        end
      Outcome.new(scanned: scanned, unplaced: unplaced, summary: summary)
    end

    sig { params(outcome: Outcome).void }
    def record(outcome)
      Activity.record(source: "integrations", event: "arr.#{@event.underscore}",
        severity: outcome.unplaced.any? ? Activity::Severity::Warn : Activity::Severity::Info,
        household_id: @webhook.household_id, summary: outcome.summary,
        payload: { source: @source, event: @event, scanned: outcome.scanned, unplaced: outcome.unplaced })
    end
  end
end
