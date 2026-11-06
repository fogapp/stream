# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Server-wide work (scan everything, prune, dump the database) and its
    # history across households: an admin's console.
    class BackgroundJobsController < BaseController
      before_action :require_admin!

      sig { void }
      def index
        render json: ManagedJobs::ALL.map { |definition|
          JobRunSerializer.job_json(definition, runs: JobRun.where(job_key: definition.key).recent.limit(20).to_a)
        }
      end

      sig { void }
      def run
        definition = ManagedJobs.find(params.require(:key).to_s)
        return render_not_found if definition.nil?

        job_run = ManagedJobs.trigger!(definition: definition, household: current_household!)
        return render_errors("That job is already running", status: :conflict) if job_run.nil?

        render json: JobRunSerializer.run_json(job_run), status: :accepted
      end
    end
  end
end
