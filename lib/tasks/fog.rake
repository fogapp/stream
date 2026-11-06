# typed: false
# frozen_string_literal: true

# The fog-backup/2 boot tasks (fog:docs/backup-contract.md).
#
# fog:release is the app's release phase on fog: restore a staged artifact if
# one is armed, then db:prepare (which migrates a restored-from-older-code
# database forward), then post-restore reconciliation. It replaces the bare
# db:prepare in stream.fog.yaml.
#
# fog:restore_if_staged is the entrypoint guard for container restarts that
# aren't deploys (the setup wizard's restore door): same work, but only when
# something is actually staged, so a plain restart stays a plain restart.
namespace :fog do
  desc "Release phase: restore staged artifact if armed, then db:prepare"
  task release: :environment do
    restored = FogBackup::Restorer.run_if_armed!
    Rake::Task["db:prepare"].invoke
    FogTasks.post_restore! if restored
  end

  desc "Restore a staged artifact if one is armed (entrypoint guard)"
  task restore_if_staged: :environment do
    next unless FogBackup::Staging.armed?

    restored = FogBackup::Restorer.run_if_armed!
    if restored
      Rake::Task["db:prepare"].invoke
      FogTasks.post_restore!
    end
  end
end

module FogTasks
  # Reconciliation after a successful restore. Stream's artifact has no
  # external components yet (see FogBackup::Manifest.external_sections), so
  # there is nothing to reconcile — the stream stays so a future component
  # (a review-hold tree, say) has a place to check itself.
  def self.post_restore!
    puts "fog: restore complete"
  end
end
