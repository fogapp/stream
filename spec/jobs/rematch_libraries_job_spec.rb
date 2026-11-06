# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe RematchLibrariesJob do
  let(:household) { Household.create!(name: "H") }
  let(:library) { create_library(household: household, roots: build_root, name: "Movies") }

  def movie_file(title, state)
    file = MediaFile.create!(household: household, library: library, path: File.join(library.roots.first, "#{title}.mkv"),
      size: 1, mtime: Time.current, state: "probed")
    Movie.create!(household: household, library: library, title: title, match_state: state).editions.create!(media_file: file)
    file
  end

  it "refiles unmatched titles and ones waiting in Needs match, but leaves matched ones" do
    unmatched = movie_file("Unmatched", "unmatched")
    waiting = movie_file("Waiting", "needs_review")
    movie_file("Matched", "matched")

    expect { described_class.perform_now(household.id) }.to have_enqueued_job(MatchMediaFileJob).exactly(2).times
    expect(MatchMediaFileJob).to have_been_enqueued.with(unmatched.id, library.id)
    expect(MatchMediaFileJob).to have_been_enqueued.with(waiting.id, library.id)
  end
end
