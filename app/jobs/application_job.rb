# typed: strict
# frozen_string_literal: true

# Base job (ported from manor:app/jobs/application_job.rb):
# - polynomial retry as the baseline; a subclass's own retry_on takes
#   precedence (most-recently-registered handler wins in ActiveJob);
# - trace_id propagation so one causal episode threads request → jobs →
#   activity entries;
# - after_discard: only *permanent* failures (retries exhausted or discarded)
#   record an error-severity activity entry — intermediate retries stay quiet.
class ApplicationJob < ActiveJob::Base
  extend T::Sig

  retry_on StandardError, wait: :polynomially_longer, attempts: 3
  retry_on ActiveRecord::Deadlocked
  discard_on ActiveJob::DeserializationError
  # A validation failure is a verdict, not a blip — the same write against
  # the same record fails the same way, so retrying re-runs the job's full
  # cost (an hour of transcription, a whole sweep) twice more to report one
  # bug, and delays the dead-letter signal by the cumulative backoff.
  # Deliberately narrow: NotFound and nil errors can be enqueue/commit races
  # that a later attempt genuinely wins, so those keep the blanket retry.
  discard_on ActiveRecord::RecordInvalid
  discard_on ActiveRecord::RecordNotSaved

  after_discard do |job, error|
    next unless job.report_death?(error)

    Activity.record(
      source: "jobs",
      event: "job.dead",
      severity: Activity::Severity::Error,
      summary: "#{job.class.name} permanently failed: #{error.class}: #{error.message.to_s.truncate(200)}",
      payload: { job_class: job.class.name, job_id: job.job_id, queue: job.queue_name }
    )
  end

  # Whether this dead job deserves a job.dead entry. True by default — dying
  # quietly is the failure mode this base class exists to prevent. A subclass
  # may say no for errors that are already recorded as a first-class fact
  # somewhere better (FetchSourceJob: on the source itself), where the dead
  # letter would be the same fact twice.
  sig { overridable.params(_error: Exception).returns(T::Boolean) }
  def report_death?(_error) = true

  sig { returns(T::Hash[String, T.untyped]) }
  def serialize
    super.merge("stream_trace_id" => Current.trace_id, "stream_job_run_id" => @stream_job_run_id)
  end

  sig { params(job_data: T::Hash[String, T.untyped]).void }
  def deserialize(job_data)
    super
    @stream_trace_id = T.let(job_data["stream_trace_id"], T.nilable(String))
    @stream_job_run_id = T.let(job_data["stream_job_run_id"], T.nilable(String))
  end

  # A JobRun around the job's work, with attempt continuity: the first attempt creates the row,
  # a retry re-serializes the job carrying its id, and the same row flips
  # back to running — the model's "a retry flips the same row" promise held
  # only for ids passed in explicitly; a fetch that failed twice then
  # succeeded used to read as three separate runs in the console.
  sig do
    params(job_key: String, household_id: T.nilable(String), job_run_id: T.nilable(String),
      block: T.proc.returns(T.nilable(String))).returns(T.nilable(String))
  end
  def track_run(job_key:, household_id: nil, job_run_id: nil, &block)
    run = JobRun.resolve(job_key: job_key, household_id: household_id,
      job_run_id: job_run_id || @stream_job_run_id)
    @stream_job_run_id = T.let(run.id, T.nilable(String))
    run.execute(&block)
  end

  around_perform do |job, block|
    trace = T.unsafe(job).instance_variable_get(:@stream_trace_id) || SecureRandom.uuid
    Current.set(trace_id: trace) { block.call }
  end
end
