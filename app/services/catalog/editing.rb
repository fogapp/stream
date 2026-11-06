# typed: strict
# frozen_string_literal: true

module Catalog
  # A person's corrections to a title's details (PROPOSAL §4.2). Each field
  # changed is locked, so no refresh from TMDB writes it again; unlocking
  # hands it back to TMDB and refreshes.
  module Editing
    extend T::Sig

    Record = T.type_alias { T.any(Movie, Show, Episode) }

    FIELDS = T.let({
      "Movie" => { "title" => :string, "original_title" => :string, "year" => :integer, "release_date" => :date,
                   "tagline" => :string, "overview" => :text, "genres" => :list, "content_rating" => :string },
      "Show" => { "title" => :string, "original_title" => :string, "year" => :integer, "overview" => :text,
                  "genres" => :list, "content_rating" => :string, "network" => :string, "status" => :string },
      "Episode" => { "title" => :string, "overview" => :text, "air_date" => :date }
    }.freeze, T::Hash[String, T::Hash[String, Symbol]])

    class Invalid < StandardError; end

    sig { params(record: Record, changes: T::Hash[String, T.untyped], unlock: T::Array[String]).returns(Record) }
    def self.edit(record, changes:, unlock: [])
      fields = FIELDS.fetch(record.class.name.to_s)
      changed = changes.select { |field, _| fields.key?(field) }.filter_map do |field, raw|
        value = cast(raw, fields.fetch(field))
        next if record.public_send(field) == value

        record.public_send(:"#{field}=", value)
        field
      end
      unlocked = unlock & record.locked_fields
      record.locked_fields = ((record.locked_fields | changed) - unlocked).sort
      raise Invalid, record.errors.full_messages.to_sentence unless record.save

      RefreshMetadataJob.perform_later(record.class.name.to_s, record.id) if unlocked.any?
      record
    end

    sig { params(raw: T.untyped, type: Symbol).returns(T.untyped) }
    def self.cast(raw, type)
      text = raw.is_a?(Array) ? raw : raw.to_s.strip
      case type
      when :integer then text.to_s.empty? ? nil : Integer(text.to_s, 10)
      when :date then text.to_s.empty? ? nil : Date.iso8601(text.to_s)
      when :list then (text.is_a?(Array) ? text : text.to_s.split(",")).map { |item| item.to_s.strip }.compact_blank.uniq
      else text.to_s.empty? ? nil : text.to_s
      end
    rescue ArgumentError, Date::Error
      raise Invalid, "#{raw.inspect} isn't a valid #{type == :date ? 'date (YYYY-MM-DD)' : 'number'}"
    end
    private_class_method :cast
  end
end
