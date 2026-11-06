# typed: strict
# frozen_string_literal: true

# One of several things a person named (a screen, a profile, a stream):
# the one called exactly that, else the first whose name starts so, else —
# when `loosely` — the first whose name contains it. Case and a leading
# "the" aside.
module NameMatch
  extend T::Sig

  sig do
    type_parameters(:T)
      .params(items: T::Array[T.type_parameter(:T)], wanted: String, loosely: T::Boolean,
        names: T.proc.params(item: T.type_parameter(:T)).returns(T::Array[String]))
      .returns(T.nilable(T.type_parameter(:T)))
  end
  def self.find(items, wanted, loosely: true, &names)
    text = normal(wanted)
    named = items.map { |item| [ item, names.call(item).map { |name| normal(name) } ] }
    found = named.find { |_, candidates| candidates.include?(text) } ||
            named.find { |_, candidates| candidates.any? { |candidate| candidate.start_with?(text) } }
    found ||= named.find { |_, candidates| candidates.any? { |candidate| candidate.include?(text) } } if loosely
    found&.first
  end

  sig { params(text: String).returns(String) }
  def self.normal(text) = text.strip.downcase.delete_prefix("the ")
  private_class_method :normal
end
