# typed: strict
# frozen_string_literal: true

module Playback
  # A request waiting a moment for something the transcoder or a job is
  # making: a Puma thread held, so never for longer than it's told, nor once
  # whoever asked has hung up.
  module Wait
    extend T::Sig

    class Outcome < T::Enum
      enums do
        Done = new
        TimedOut = new
        # The client has gone: nobody is waiting any more.
        Abandoned = new
      end
    end

    sig do
      params(seconds: Float, every: Float, gone: T.proc.returns(T::Boolean), condition: T.proc.returns(T::Boolean)).returns(Outcome)
    end
    def self.until(seconds, every:, gone:, &condition)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f + seconds
      loop do
        return Outcome::Done if condition.call
        return Outcome::Abandoned if gone.call
        return Outcome::TimedOut if Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f > deadline

        sleep every
      end
    end
  end
end
