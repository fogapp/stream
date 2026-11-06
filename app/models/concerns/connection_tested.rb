# typed: strict
# frozen_string_literal: true

# A connection a person tests from Settings. The last test's time, outcome and
# message live on the row, so the screen can say how the last test went
# without running it again; this is the one writer for them.
module ConnectionTested
  extend ActiveSupport::Concern
  extend T::Sig
  extend T::Helpers

  requires_ancestor { ApplicationRecord }

  MESSAGE_LIMIT = 250

  sig { params(ok: T::Boolean, message: String).void }
  def record_test!(ok, message)
    update!(last_tested_at: Time.current, last_test_ok: ok, last_test_message: message.truncate(MESSAGE_LIMIT))
  end
end
