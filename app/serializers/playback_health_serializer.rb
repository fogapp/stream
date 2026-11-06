# typed: strict
# frozen_string_literal: true

# The Playback page's health strip (Playback::Health): each check, and the
# worst of them for the page as a whole.
module PlaybackHealthSerializer
  extend T::Sig

  sig { params(checks: T::Array[Playback::Health::Check]).returns(T::Hash[Symbol, T.untyped]) }
  def self.json(checks)
    order = Playback::Health::Status.values
    worst = checks.map(&:status).max_by { |status| order.index(status).to_i } || Playback::Health::Status::Ok
    {
      status: worst,
      checks: checks.map do |check|
        { key: check.key, status: check.status, title: check.title, metric: check.metric, detail: check.detail,
          action: check.action, link: check.link }
      end
    }
  end
end
