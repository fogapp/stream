# typed: strict
# frozen_string_literal: true

require "tapioca/dsl"

module Tapioca
  module Compilers
    # Generates the `set_<name>` / `<name>` methods that BaseController.finds
    # defines (hub:sorbet/tapioca/compilers/controller_finders.rb). The reader
    # is intentionally T.untyped: the scope's element type isn't knowable from
    # the lambda, and forcing a cast here would defeat the macro's purpose.
    class ControllerFinders < Tapioca::Dsl::Compiler
      extend T::Sig

      ConstantType = type_member { { fixed: T.class_of(Api::V1::BaseController) } }

      sig { override.returns(T::Enumerable[T::Module[T.anything]]) }
      def self.gather_constants
        descendants_of(Api::V1::BaseController).select { |klass| klass.finder_names.any? }
      end

      sig { override.void }
      def decorate
        names = constant.finder_names
        return if names.empty?

        root.create_path(constant) do |controller|
          names.each do |name|
            controller.create_method("set_#{name}", return_type: "void", visibility: RBI::Private.new)
            controller.create_method(name.to_s, return_type: "T.untyped", visibility: RBI::Private.new)
          end
        end
      end
    end
  end
end
