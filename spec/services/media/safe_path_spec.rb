# typed: false
# frozen_string_literal: true

require "rails_helper"

# The one containment check behind every byte Stream serves from a library
# (Library#root_for → /media/s, /media/n, /media/d) and every file it deletes
# or trusts yt-dlp to have written. Real folders and real symlinks throughout.
RSpec.describe Media::SafePath do
  include RequestHelpers

  let(:base) { Pathname(Dir.mktmpdir("safe-path")) }
  let(:movies) { base.join("movies").tap(&:mkpath) }
  let(:elsewhere) { base.join("elsewhere").tap(&:mkpath) }

  after { FileUtils.rm_rf(base) }

  def touch(path)
    path.dirname.mkpath
    path.write("x")
    path
  end

  describe ".within?" do
    it "holds a path inside its root, and the root itself" do
      expect(described_class.within?(touch(movies.join("Heat (1995)/Heat.mkv")).to_s, movies.to_s)).to be(true)
      expect(described_class.within?(movies.to_s, movies.to_s)).to be(true)
      expect(described_class.within?(movies.to_s, "#{movies}/")).to be(true)
    end

    it "treats a sibling that shares a prefix as outside" do
      old = touch(base.join("movies-old/Heat.mkv"))

      expect(described_class.within?(old.to_s, movies.to_s)).to be(false)
    end

    it "sees through dot-dot" do
      secret = touch(elsewhere.join("secret.mkv"))

      expect(described_class.within?("#{movies}/../elsewhere/secret.mkv", movies.to_s)).to be(false)
      expect(described_class.within?(secret.to_s, movies.to_s)).to be(false)
    end

    it "follows a symlink out of the root to where it really points" do
      secret = touch(elsewhere.join("secret.mkv"))
      File.symlink(secret, movies.join("innocent.mkv"))
      File.symlink(elsewhere, movies.join("linked-folder"))

      expect(described_class.within?(movies.join("innocent.mkv").to_s, movies.to_s)).to be(false)
      expect(described_class.within?(movies.join("linked-folder/secret.mkv").to_s, movies.to_s)).to be(false)
    end

    it "accepts a symlinked root, resolving both sides the same way" do
      heat = touch(movies.join("Heat.mkv"))
      File.symlink(movies, base.join("movies-link"))

      expect(described_class.within?(heat.to_s, base.join("movies-link").to_s)).to be(true)
      expect(described_class.within?(base.join("movies-link/Heat.mkv").to_s, movies.to_s)).to be(true)
    end

    it "judges a path that no longer exists by the folders above it" do
      expect(described_class.within?(movies.join("Deleted/Gone.mkv").to_s, movies.to_s)).to be(true)
      expect(described_class.within?(elsewhere.join("Gone.mkv").to_s, movies.to_s)).to be(false)
    end
  end

  describe ".real" do
    it "is nil for a file that isn't there or a link that points nowhere" do
      File.symlink(base.join("nothing"), movies.join("dangling.mkv"))

      expect(described_class.real(movies.join("absent.mkv").to_s)).to be_nil
      expect(described_class.real(movies.join("dangling.mkv").to_s)).to be_nil
    end
  end

  describe "Library#root_for" do
    let(:household) { create_household }
    let(:library) { create_library(household: household, roots: [ movies.to_s ]) }

    it "answers the root a real file sits under, and nothing for one that escapes or is gone" do
      heat = touch(movies.join("Heat.mkv"))
      File.symlink(touch(elsewhere.join("secret.mkv")), movies.join("escape.mkv"))

      expect(library.root_for(heat.to_s)).to eq(movies.to_s)
      expect(library.root_for(movies.join("escape.mkv").to_s)).to be_nil
      expect(library.root_for(movies.join("gone.mkv").to_s)).to be_nil
      expect(library.root_for(base.join("movies-old/Heat.mkv").to_s)).to be_nil
    end
  end
end
