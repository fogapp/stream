# typed: false
# frozen_string_literal: true

# The test queue adapter accumulates enqueued jobs for the whole process, so
# without this any spec that inspects `enqueued_jobs` sees whatever earlier
# examples left behind — passing alone and failing in the suite, or worse,
# passing for the wrong reason. Clearing between examples makes job
# assertions mean what they say.
RSpec.configure do |config|
  config.include ActiveJob::TestHelper

  config.before do
    clear_enqueued_jobs
    clear_performed_jobs
    # The queue tables (the heavy queue's pause among them) live in a
    # separate database in production and aren't in the test schema: a
    # read's hold would abort the example's transaction asking. Nobody's
    # watching, unless a spec says so.
    allow(HoldHeavyWhileWatchingJob).to receive(:holding?).and_return(false)
  end
end
