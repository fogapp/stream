# typed: strict
# frozen_string_literal: true

module Libraries
  # The folders fog mounts into Stream that no library reads yet, each with
  # the kind its Drive folder's name suggests ("Movies" → movies) and the
  # library it would join — the only library of that kind, when there is
  # one. A suggestion, never a library: an admin adds it (CLAUDE.md, "paths
  # are configured in-app and never assumed"). Empty outside fog.
  class FogSuggestions
    extend T::Sig

    KINDS = T.let({
      "movies" => "movies", "films" => "movies",
      "tv" => "shows", "shows" => "shows", "television" => "shows", "series" => "shows",
      "youtube" => "channels", "channels" => "channels",
      "videos" => "home_videos", "home videos" => "home_videos"
    }.freeze, T::Hash[String, String])

    class Suggestion < T::Struct
      const :root, String
      const :name, String
      const :kind, String
      const :library_id, T.nilable(String)
      const :library_name, T.nilable(String)
    end

    sig { params(household_id: String, api: Fog::Api).void }
    def initialize(household_id, api: Fog::Api.new)
      @household_id = household_id
      @api = api
    end

    sig { returns(T::Array[Suggestion]) }
    def call
      mounts = @api.mounts
      return [] if mounts.nil?

      libraries = Library.unscoped.where(household_id: @household_id).to_a
      mounts.filter_map do |m|
        next if libraries.any? { |library| library.roots.any? { |root| Media::SafePath.within?(m.mount, root) || Media::SafePath.within?(root, m.mount) } }

        name = File.basename(m.host_path)
        kind = KINDS[name.downcase]
        next if kind.nil?

        same = libraries.select { |library| library.kind_enum.serialize == kind }
        target = same.length == 1 ? same.first : nil
        Suggestion.new(root: m.mount, name: name, kind: kind, library_id: target&.id, library_name: target&.name)
      end
    end
  end
end
