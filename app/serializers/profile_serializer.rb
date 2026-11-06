# typed: strict
# frozen_string_literal: true

# A profile as the picker, Settings › Profiles and a TV read it (PROPOSAL
# §7.4). Never its PIN: only whether it has one.
module ProfileSerializer
  extend T::Sig

  sig { params(profile: Profile).returns(T::Hash[Symbol, T.untyped]) }
  def self.json(profile)
    {
      id: profile.id, name: profile.name, color: profile.color, avatar: profile.avatar, has_pin: profile.pin?, kind: profile.kind_enum.serialize,
      max_rating_age: profile.max_rating_age, allow_unrated: profile.allow_unrated, library_ids: profile.library_ids, curated: profile.curated,
      up_next_seconds: profile.up_next_seconds, always_skip_intro: profile.always_skip_intro, always_skip_credits: profile.always_skip_credits,
      still_watching_after: profile.still_watching_after, autoplay_videos: profile.autoplay_videos
    }
  end
end
