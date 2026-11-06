# typed: strict
# frozen_string_literal: true

# fog-files/1 (fog:docs/files-contract.md): fog says a folder Stream mounts
# changed under it — files written through Drive, a peer's copy synced, a
# folder moved. The notice carries no listing; the response is to look
# again: every library reading that folder scans it. Answers fast and does
# the walking in jobs, since fog gives the call seconds and never retries.
class FogFilesController < ActionController::API
  extend T::Sig
  include FogContractAuth

  sig { void }
  def changed
    mount = params[:mount].to_s.chomp("/").presence
    libraries = Library.unscoped.to_a
    libraries = libraries.select { |library| library.roots.any? { |root| overlaps?(root, mount) } } if mount
    libraries.each do |library|
      target = mount && library.roots.any? { |root| Media::SafePath.within?(mount, root) } ? mount : nil
      ScanLibraryJob.perform_later(library.id, target)
    end
    head :ok
  end

  private

  sig { params(root: String, mount: String).returns(T::Boolean) }
  def overlaps?(root, mount) = Media::SafePath.within?(mount, root) || Media::SafePath.within?(root, mount)
end
