# typed: strict
# frozen_string_literal: true

# Delivers one ntfy push off the request path. Notifier writes the durable
# in-app row synchronously; the network round trip to the push relay is the
# part nobody should wait on.
class PushNotificationJob < ApplicationJob
  extend T::Sig

  queue_as :default
  # One push at a time: they arrive at the relay in the order they happened.
  limits_concurrency to: 1, key: "ntfy_push"

  sig { params(title: String, kind: String).void }
  def perform(title:, kind:)
    Notifier.push_ntfy(title: title, kind: kind)
  end
end
