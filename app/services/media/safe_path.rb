# typed: strict
# frozen_string_literal: true

module Media
  # Path containment, done once and done right (PROPOSAL §10): a path is
  # inside a root only after both are resolved through symlinks, and "inside"
  # means a path-segment boundary — /media/movies-old is not inside
  # /media/movies.
  module SafePath
    extend T::Sig

    # The canonical path, or nil when it doesn't exist or can't be read.
    sig { params(path: String).returns(T.nilable(String)) }
    def self.real(path)
      File.realpath(path)
    rescue SystemCallError
      nil
    end

    sig { params(path: String, root: String).returns(T::Boolean) }
    def self.within?(path, root)
      real_root = resolve(root)
      real_path = resolve(path)
      real_path == real_root || real_path.start_with?("#{real_root.chomp('/')}/")
    end

    # realpath for a path that may not exist (a folder Sonarr just deleted):
    # resolve the nearest ancestor that does, keep the rest as written. So a
    # symlinked parent (macOS's /var) resolves the same way for both sides.
    sig { params(path: String).returns(String) }
    def self.resolve(path)
      existing = Pathname.new(path).cleanpath
      rest = T.let([], T::Array[String])
      resolved = T.let(real(existing.to_s), T.nilable(String))
      while resolved.nil? && !existing.root?
        rest.unshift(existing.basename.to_s)
        existing = existing.dirname
        resolved = real(existing.to_s)
      end
      ([ resolved || existing.to_s ] + rest).join("/").squeeze("/")
    end
  end
end
