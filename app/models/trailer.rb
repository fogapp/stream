# typed: strict
# frozen_string_literal: true

# A film's or show's trailer (PROPOSAL §7.1–7.2): the YouTube video TMDB
# names as its official trailer, fetched into storage by FetchTrailerJob.
# Only a ready one is ever offered.
class Trailer < ApplicationRecord
  # Written, never read: dropped once no replica can still be writing it.
  self.ignored_columns += %w[fetched_at]

  extend T::Sig
  include HouseholdScoped

  class State < T::Enum
    include ApplicationEnum
    enums do
      Queued = new("queued")
      Ready = new("ready")
      Failed = new("failed")
    end
  end

  MAX_ATTEMPTS = 3

  belongs_to :owner, polymorphic: true

  attribute :state, State

  after_destroy_commit :remove_file

  sig { returns(Pathname) }
  def self.root
    StreamPaths.storage.join("trailers")
  end

  sig { returns(Pathname) }
  def path = self.class.root.join("#{id}.mp4")

  sig { returns(T::Boolean) }
  def ready? = state_enum == State::Ready && path.file?

  private

  sig { void }
  def remove_file
    FileUtils.rm_f(path)
  end
end
