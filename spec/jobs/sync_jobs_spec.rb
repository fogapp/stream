# typed: false
# frozen_string_literal: true

require "rails_helper"

# The nightly syncs: each fans out to the households that switched it on,
# and a sync already done is never run again.
RSpec.describe "Sync jobs" do
  include RequestHelpers

  let(:household) { create_household }

  it "syncs Immich for each household that has it switched on" do
    other = create_household(name: "Off")
    ImmichSetting.create!(household: household, url: "http://immich.lan:2283", api_key: "k", enabled: true)
    ImmichSetting.create!(household: other, url: "http://immich.lan:2283", api_key: "k", enabled: false)

    ImmichSyncsJob.perform_now

    expect(ImmichSyncJob).to have_been_enqueued.with(household.id)
    expect(ImmichSyncJob).not_to have_been_enqueued.with(other.id)

    allow(Immich::Sync).to receive(:new).and_call_original
    ImmichSyncJob.perform_now(other.id)
    expect(Immich::Sync).not_to have_received(:new)
  end

  # Both reach the sites below as siblings of Tmdb::Client::Error: a revoked
  # key mustn't be a dead letter per title, nor a 429 the end of the job.
  describe "TMDB refusing" do
    let(:library) { create_library(household: household, roots: build_root) }
    let(:movie) { Movie.create!(household: household, library: library, title: "Heat", tmdb_id: 949) }
    let(:collection) { Collection.create!(household: household, kind: "tmdb", title: "Set", tmdb_id: 7) }

    before { TmdbSetting.create!(household: household, api_key: "k") }

    it "records a revoked key on a collection's sync, rather than dying" do
      stub_request(:get, %r{api.themoviedb.org/3/collection/7}).to_return(status: 401, body: "{}")

      SyncCollectionJob.perform_now(collection.id)

      expect(ActivityEntry.where(event: "collection.fetch_failed").count).to eq(1)
      expect(ActivityEntry.where(event: "job.dead")).to be_empty
      expect(enqueued_jobs).to be_empty
    end

    it "records a revoked key on a metadata refresh, rather than dying" do
      stub_request(:get, %r{api.themoviedb.org/3/movie/949}).to_return(status: 401, body: "{}")

      RefreshMetadataJob.perform_now("Movie", movie.id)

      expect(ActivityEntry.where(event: "metadata.refresh_failed").count).to eq(1)
      expect(enqueued_jobs).to be_empty
    end

    it "leaves a rate limit to the job's retry" do
      stub_request(:get, %r{api.themoviedb.org/3/collection/7}).to_return(status: 429, body: "{}")

      SyncCollectionJob.perform_now(collection.id)

      expect(ActivityEntry.where(event: "collection.fetch_failed")).to be_empty
      expect(enqueued_jobs.map { |job| job["job_class"] }).to eq([ "SyncCollectionJob" ])
    end
  end

  it "queues one Plex import per connection that syncs, and says how many on its run" do
    PlexConnection.create!(household: household, server_url: "http://plex.lan:32400", token: "t", machine_identifier: "a", sync_enabled: true)
    quiet = create_household(name: "Quiet")
    PlexConnection.create!(household: quiet, server_url: "http://plex.lan:32400", token: "t", machine_identifier: "b", sync_enabled: false)

    PlexSyncJob.perform_now

    import = PlexImport.unscoped.sole
    expect(import).to have_attributes(household_id: household.id, dry_run: false)
    expect(PlexImportJob).to have_been_enqueued.with(import.id)
    expect(JobRun.find_by(job_key: PlexSyncJob::JOB_KEY)).to have_attributes(status: "succeeded", message: "1 Plex sync queued")
  end

  it "never runs a finished Plex import again" do
    import = PlexImport.create!(household: household, dry_run: false, status: "succeeded")
    allow(Plex::Migration).to receive(:new)

    PlexImportJob.perform_now(import.id)
    PlexImportJob.perform_now(SecureRandom.uuid)

    expect(Plex::Migration).not_to have_received(:new)
  end

  describe SyncArtworkJob do
    let(:library) { create_library(household: household, roots: build_root, kind: "channels", name: "YouTube") }

    before do
      [ Artworks::Sync, Artworks::Local, Artworks::FrameGrab ].each do |source|
        allow(source).to receive(:new).and_return(instance_double(source, call: nil))
      end
      allow(Artworks::YoutubeImages).to receive(:sync)
      allow(Artworks::ImmichFaces).to receive(:sync)
    end

    it "asks each kind of thing for its picture where that kind keeps one" do
      movie = Movie.create!(household: household, library: create_library(household: household, roots: build_root), title: "Heat")
      channel = Channel.create!(household: household, library: library, folder: "TC", title: "TC")
      video = Video.create!(household: household, library: library, channel: channel, title: "Talk", source: "folder")
      person = HomePerson.create!(household: household, immich_id: "p1", name: "Ada")

      described_class.perform_now("Movie", movie.id)
      expect(Artworks::Sync).to have_received(:new).with(movie)
      expect(Artworks::FrameGrab).to have_received(:new).with(movie) # a frame if the provider has nothing

      described_class.perform_now("Channel", channel.id)
      expect(Artworks::Local).to have_received(:new).with(channel)
      expect(Artworks::YoutubeImages).to have_received(:sync).with(channel)

      described_class.perform_now("Video", video.id)
      expect(Artworks::Local).to have_received(:new).with(video)
      expect(Artworks::FrameGrab).to have_received(:new).with(video)

      described_class.perform_now("HomePerson", person.id)
      expect(Artworks::ImmichFaces).to have_received(:sync).with(person)
    end

    it "ignores what isn't a picture owner, and what's gone" do
      described_class.perform_now("User", SecureRandom.uuid)
      described_class.perform_now("Movie", SecureRandom.uuid)

      expect(Artworks::Sync).not_to have_received(:new)
    end
  end
end
