# typed: strict
# frozen_string_literal: true

module ActivityEntrySerializer
  extend T::Sig

  # Callers that render a page of entries preload `:subject` — subject_json
  # reads the association, and an unpreloaded page of a hundred rows is a
  # hundred lookups.
  sig { params(entry: ActivityEntry).returns(T::Hash[Symbol, T.untyped]) }
  def self.entry_json(entry)
    {
      id: entry.id, source: entry.source, event: entry.event,
      severity: entry.severity, summary: entry.summary,
      subject_type: entry.subject_type, subject_id: entry.subject_id,
      subject: subject_json(entry),
      payload: entry.payload, duration_ms: entry.duration_ms,
      trace_id: entry.trace_id, created_at: entry.created_at
    }
  end

  # What the entry is about, as something a person can read and open. The
  # polymorphic columns alone tell the console "MediaFile 3f9a…"; a name and a
  # console path are what make an event legible at a glance. Label and path
  # are nil when the subject has since been deleted (the entry outlives it by
  # design) or is a type the console has no page for.
  sig { params(entry: ActivityEntry).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
  def self.subject_json(entry)
    type = entry.subject_type
    return nil if type.nil?

    label, path = describe(entry.subject)
    { type: type, id: entry.subject_id, label: label, path: path }
  end

  # Each domain model with a console page adds a branch here as it lands.
  sig { params(subject: T.untyped).returns([ T.nilable(String), T.nilable(String) ]) }
  def self.describe(subject)
    case subject
    when User then [ subject.name, "/settings?tab=users" ]
    else [ nil, nil ]
    end
  end
  private_class_method :describe
end
