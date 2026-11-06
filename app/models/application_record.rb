# typed: strict
# frozen_string_literal: true

class ApplicationRecord < ActiveRecord::Base
  extend T::Sig

  primary_abstract_class

  # Registry of enum-typed attributes, read by the tapioca compiler
  # (sorbet/tapioca/compilers/typed_enum_attribute.rb) to generate sigs for
  # the *_enum accessors.
  TypedEnumAttribute = Struct.new(:name, :enum, :allow_nil)

  class_attribute :typed_enum_attributes, instance_accessor: false, default: []

  class << self
    extend T::Sig

    # For a model with one row per household (a unique index on household_id):
    # that household's row, created the first time anyone asks. Two first asks
    # race to the index, and the loser reads the winner's row.
    sig { params(household: Household).returns(T.attached_class) }
    def for_household!(household)
      unscoped.find_or_create_by!(household_id: household.id)
    rescue ActiveRecord::RecordNotUnique
      unscoped.find_by!(household_id: household.id)
    end

    # An ordered list's rows (a playlist's, a collection's) put in the order
    # of `item_ids`, any not named after them: one UPDATE, not one per row.
    sig { params(rows: T.untyped, item_ids: T::Array[String]).void }
    def reposition!(rows, item_ids)
      ids = item_ids.grep(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
      cases = ids.each_with_index.map { |id, index| sanitize_sql_array([ "WHEN ? THEN ?", id, index ]) }.join(" ")
      position = cases.empty? ? ids.size.to_s : "CASE item_id::text #{cases} ELSE #{ids.size} END"
      rows.update_all(Arel.sql("position = #{position}, updated_at = #{connection.quote(Time.current)}")) # rubocop:disable Rails/SkipsModelValidations
    end

    # `attribute :kind, SomeEnum` wires a closed vocabulary onto a plain string
    # column: inclusion validation from the enum's own values, plus typed
    # `kind_enum` / `kind_enum=` accessors. Columns stay strings on disk for
    # greppability; never hand-roll `validates :x, inclusion:` for a closed set
    # (hub convention).
    sig do
      params(name: T.any(Symbol, String), type: T.untyped, options: T.untyped).void
    end
    def attribute(name, type = nil, **options)
      if type.is_a?(Class) && type < T::Enum
        enum_class = type
        allow_nil = options.delete(:allow_nil) ? true : false
        self.typed_enum_attributes += [ TypedEnumAttribute.new(name.to_sym, enum_class, allow_nil) ]
        validates name, inclusion: { in: enum_class.values.map(&:serialize) }, allow_nil: allow_nil

        define_method(:"#{name}_enum") do
          raw = public_send(name)
          raw.nil? ? nil : enum_class.try_deserialize(raw)
        end
        define_method(:"#{name}_enum=") do |value|
          public_send(:"#{name}=", value.nil? ? nil : T.cast(value, T::Enum).serialize)
        end
        super(name, :string, **options)
      else
        type.nil? ? super(name, **options) : super
      end
    end
  end
end
