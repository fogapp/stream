# typed: strict
# frozen_string_literal: true

# Certifications as ages (PROPOSAL §7.4), so one ceiling works across the
# systems titles arrive with: US film and TV, UK, and the common others.
module ContentRatings
  extend T::Sig

  AGES = T.let({
    # US film (MPA) and TV parental guidelines.
    "G" => 0, "PG" => 8, "PG-13" => 13, "R" => 17, "NC-17" => 18,
    "TV-Y" => 0, "TV-Y7" => 7, "TV-Y7-FV" => 7, "TV-G" => 0, "TV-PG" => 10, "TV-14" => 14, "TV-MA" => 17,
    # UK (BBFC), Australia, Germany (FSK), Netherlands, France and others that are plain numbers.
    "U" => 0, "UC" => 0, "12A" => 12, "M" => 15, "MA15+" => 15, "MA 15+" => 15, "R18+" => 18, "X18+" => 18,
    "FSK 0" => 0, "FSK 6" => 6, "FSK 12" => 12, "FSK 16" => 16, "FSK 18" => 18, "AL" => 0, "TP" => 0
  }.freeze, T::Hash[String, Integer])

  # The choices a profile's ceiling offers, youngest first.
  CEILINGS = T.let([ 0, 7, 10, 13, 16 ].freeze, T::Array[Integer])

  sig { params(rating: T.nilable(String)).returns(T.nilable(Integer)) }
  def self.age(rating)
    text = rating.to_s.strip.upcase
    return nil if text.empty? || %w[NR UNRATED NOT\ RATED].include?(text)

    AGES[text] || text[/\A(\d{1,2})\+?\z/, 1]&.to_i
  end
end
