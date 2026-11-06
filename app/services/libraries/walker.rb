# typed: strict
# frozen_string_literal: true

module Libraries
  # Walks a folder on a share, one lstat an entry, telling what's gone from
  # what couldn't be read. Find can't: it skips anything it can't list or
  # stat, so a folder that timed out reads exactly like an empty one, and
  # the Scanner would call everything under it missing.
  #
  # A link to a file is that file. A link to a folder isn't followed, nor is
  # a root that's a link, so nothing is found twice by two ways in.
  class Walker
    extend T::Sig

    # The share's answer that a path isn't there: anything else means it
    # didn't answer.
    GONE = T.let([ Errno::ENOENT, Errno::ENOTDIR ].freeze, T::Array[T.class_of(SystemCallError)])
    # A link that points nowhere is a link, and no video.
    NOWHERE = T.let([ *GONE, Errno::ELOOP ].freeze, T::Array[T.class_of(SystemCallError)])

    # What couldn't be read, folders and files alike: nothing is known about
    # these, or anything under them.
    sig { returns(T::Array[String]) }
    attr_reader :unread

    sig { params(root: String, skip: T.proc.params(name: String).returns(T::Boolean)).void }
    def initialize(root, skip:)
      @root = root
      @skip = skip
      @unread = T.let([], T::Array[String])
      @vanished = T.let(false, T::Boolean)
    end

    # Each file under the root, in path order. Not being able to read the
    # root itself raises: there's nothing to go on.
    sig { params(block: T.proc.params(path: String, info: File::Stat).void).void }
    def each_file(&block)
      visit(@root, Dir.children(@root).sort, &block) if File.lstat(@root).directory?
    end

    # Something listed was gone by the time it was looked at: a move under
    # way, or a share dropping off, for the caller to tell apart.
    sig { returns(T::Boolean) }
    def vanished? = @vanished

    private

    sig { params(dir: String, names: T::Array[String], block: T.proc.params(path: String, info: File::Stat).void).void }
    def visit(dir, names, &block)
      names.each do |name|
        path = File.join(dir, name)
        info = entry(path)
        next if info.nil?

        if !info.directory?
          yield path, info
        elsif !@skip.call(name) && (children = listing(path))
          visit(path, children, &block)
        end
      end
    end

    sig { params(dir: String).returns(T.nilable(T::Array[String])) }
    def listing(dir)
      Dir.children(dir).sort
    rescue *GONE
      @vanished = true
      nil
    rescue SystemCallError
      @unread << dir
      nil
    end

    sig { params(path: String).returns(T.nilable(File::Stat)) }
    def entry(path)
      info = File.lstat(path)
      info.symlink? ? through_link(path) : info
    rescue *GONE
      @vanished = true
      nil
    rescue SystemCallError
      @unread << path
      nil
    end

    sig { params(path: String).returns(T.nilable(File::Stat)) }
    def through_link(path)
      info = File.stat(path)
      info.directory? ? nil : info
    rescue *NOWHERE
      nil
    end
  end
end
