# typed: true

# The vendored glass agent (vendor/gems/glass) is outside Sorbet's view
# (sorbet/config ignores /vendor): sigs for the public API Stream calls.
module Glass
  sig { params(name: String, by: Numeric, tags: T::Hash[Symbol, T.untyped]).void }
  def self.increment(name, by = 1, tags: {}); end

  sig { params(name: String, ms: Numeric, tags: T::Hash[Symbol, T.untyped]).void }
  def self.timing(name, ms, tags: {}); end

  sig { params(title: String, tags: T::Hash[Symbol, T.untyped], kind: String).void }
  def self.event(title, tags: {}, kind: "event"); end

  sig { params(attrs: T.untyped).void }
  def self.tag(**attrs); end
end
