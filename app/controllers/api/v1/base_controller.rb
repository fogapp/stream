# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # House controller base (hub:app/controllers/api/v1/base_controller.rb).
    # Controllers stay thin: params in, service/serializer out. Use these
    # helpers instead of re-rolling them — cop-enforced where possible.
    class BaseController < ApplicationController
      extend T::Sig

      # Manor's corrected rescue table (its API audit found each of these as a
      # 500 in production first):
      # - ParameterMissing descends from KeyError, not BadRequest → explicit 400
      # - RecordNotUnique on double-submit → 409, not 500

      include CurrentProfile

      # Who's watching, for everything the request reads (Viewing::Access).
      before_action :set_current_profile

      rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
      rescue_from ActionController::ParameterMissing, with: :render_missing_parameter
      rescue_from ActiveRecord::RecordNotUnique, with: :render_conflict
      # A validation failure is the person's to fix: the record's own
      # messages, 422 — what every create and update rescued by hand before.
      rescue_from ActiveRecord::RecordInvalid, with: :render_invalid

      # Guests are read-only (ACCESS.md › Roles). Controllers where a guest
      # manages only their own sign-in skip this.
      before_action :deny_guest_writes

      class_attribute :finder_names, instance_accessor: false, default: []

      class << self
        extend T::Sig

        # `finds :source, from: -> { Source.all }` defines a before_action
        # `set_source` and a `source` reader — replaces the @ivar + T.must
        # ceremony (hub macro; the finder_names registry feeds a tapioca
        # compiler later).
        sig do
          params(name: Symbol, from: T.proc.returns(T.untyped), param: Symbol).void
        end
        def finds(name, from:, param: :id)
          self.finder_names += [ name ]
          ivar = "@#{name}"

          define_method(:"set_#{name}") do
            scope = T.unsafe(self).instance_exec(&from)
            record = scope.find(T.unsafe(self).params.require(param))
            instance_variable_set(ivar, record)
          end
          private :"set_#{name}"

          define_method(name) do
            unless instance_variable_defined?(ivar)
              raise "#{name} accessed before set_#{name} ran — add `before_action :set_#{name}`"
            end
            instance_variable_get(ivar)
          end
          private name

          before_action :"set_#{name}"
        end
      end

      private

      # The only error envelope is { errors: [...] } (cop-enforced). The one
      # sanctioned exception is test_connection's { ok: false, error: } shape.
      sig { params(source: T.untyped, status: Symbol).void }
      def render_errors(source, status: :unprocessable_content)
        messages =
          case source
          when String then [ source ]
          when Array then source.map(&:to_s)
          when ActiveModel::Errors then source.full_messages
          else
            model_errors = source.respond_to?(:errors) ? source.errors : nil
            model_errors.is_a?(ActiveModel::Errors) ? model_errors.full_messages : [ source.to_s ]
          end
        render json: { errors: messages }, status: status
      end

      # Accepts the optional exception because sorbet-runtime sig wrappers
      # report arity -1, which makes Rails' rescue_from pass the exception
      # even to handlers declared with zero params.
      sig { params(_exception: T.untyped).void }
      def render_not_found(_exception = nil)
        render json: { errors: [ "Not found" ] }, status: :not_found
      end

      sig { params(exception: ActionController::ParameterMissing).void }
      def render_missing_parameter(exception)
        render_errors("Missing parameter: #{exception.param}", status: :bad_request)
      end

      sig { params(_exception: T.untyped).void }
      def render_conflict(_exception = nil)
        render_errors("That already exists", status: :conflict)
      end

      sig { params(exception: ActiveRecord::RecordInvalid).void }
      def render_invalid(exception)
        render_errors(exception.record || exception.message)
      end

      # Offset pagination for list screens: response stays a bare array,
      # totals ride in headers (hub shape; the client reads X-Total-Count).
      # The merged-timeline endpoints use cursor pagination instead.
      #
      # The total is for pagers, not analytics: it counts at most COUNT_CAP
      # rows (X-Total-Count-Capped says when it hit the ceiling), because an
      # exact COUNT(*) per page view over the busiest table in the system —
      # activity, which every fetch and tool call writes to — grew with the
      # install's age rather than with the page.
      COUNT_CAP = 10_000

      sig { params(scope: T.untyped, default_per: Integer, max_per: Integer).returns(T.untyped) }
      def paginate(scope, default_per: 100, max_per: 500)
        page, per = page_params(default_per, max_per)
        total = scope.unscope(:order).limit(COUNT_CAP).count
        response.set_header("X-Total-Count", total.to_s)
        response.set_header("X-Total-Count-Capped", "true") if total >= COUNT_CAP
        response.set_header("X-Page", page.to_s)
        response.set_header("X-Per-Page", per.to_s)
        scope.offset((page - 1) * per).limit(per)
      end

      # The same envelope over rows already in memory — a report built and
      # cached whole, filtered and sorted in Ruby.
      sig { params(rows: T::Array[T.untyped], default_per: Integer, max_per: Integer).returns(T::Hash[Symbol, T.untyped]) }
      def paged_rows(rows, default_per: 50, max_per: 200)
        page, per = page_params(default_per, max_per)
        { rows: rows.slice((page - 1) * per, per) || [], total: rows.size, total_capped: false, page: page, per: per }
      end

      # Offset pagination for the console's data tables, whose pager needs the
      # total in the body: { rows:, total:, total_capped:, page:, per: }. The
      # block turns the page's records into rows.
      sig do
        params(scope: T.untyped, default_per: Integer, max_per: Integer, block: T.proc.params(records: T::Array[T.untyped]).returns(T::Array[T.untyped]))
          .returns(T::Hash[Symbol, T.untyped])
      end
      def paged(scope, default_per: 50, max_per: 200, &block)
        page, per = page_params(default_per, max_per)
        total = scope.unscope(:order).limit(COUNT_CAP).count
        rows = block.call(scope.offset((page - 1) * per).limit(per).to_a)
        { rows: rows, total: total, total_capped: total >= COUNT_CAP, page: page, per: per }
      end

      # The page and page size asked for, within bounds.
      sig { params(default_per: Integer, max_per: Integer).returns([ Integer, Integer ]) }
      def page_params(default_per, max_per)
        [ params[:page].to_i.clamp(1, 1_000_000), (params[:per].presence&.to_i || default_per).clamp(1, max_per) ]
      end

      sig { params(key: T.any(Symbol, String), default: T::Boolean).returns(T::Boolean) }
      def bool_param(key, default: false)
        raw = params[key]
        return default if raw.nil?

        ActiveModel::Type::Boolean.new.cast(raw) ? true : false
      end

      # The external-id filters asked for (`?tmdb_id=603,604&imdb_id=…`),
      # for Viewing::Catalog.with_external_ids.
      sig { params(keys: T::Array[Symbol]).returns(T::Hash[Symbol, String]) }
      def external_id_filters(keys)
        keys.select { |key| params.key?(key) }.to_h { |key| [ key, params[key].to_s ] }
      end

      # Lenient param parsers: blank or garbage input yields nil, never a 500
      # (hub convention).
      sig { params(key: T.any(Symbol, String)).returns(T.nilable(Time)) }
      def parse_param_time(key)
        raw = params[key].presence&.to_s
        return nil if raw.nil?

        Time.zone.parse(raw)
      rescue ArgumentError
        nil
      end

      sig { params(key: T.any(Symbol, String)).returns(T.nilable(Date)) }
      def parse_param_date(key)
        raw = params[key].presence&.to_s
        return nil if raw.nil?

        Date.parse(raw)
      rescue Date::Error
        nil
      end

      # Anything but a read, from a guest, is refused. Requests with no
      # signed-in user (setup, sign-in, invite acceptance) are not a guest's.
      sig { void }
      def deny_guest_writes
        return if request.get? || request.head?

        user = Current.user
        return unless user.is_a?(User) && user.guest?

        render_errors("Guests have read-only access", status: :forbidden)
      end

      # A visitor (fog:docs/signin-proposal.md §10.4) is here for as long as
      # their own fog and the pairing say: a token or passkey of their own
      # would outlive both, so they make none. Controllers that let a guest
      # manage their own sign-in call this before minting one.
      sig { void }
      def deny_visitor_credentials
        user = Current.user
        return unless user.is_a?(User) && user.visitor?

        render_errors("Visitors sign in with their own fog", status: :forbidden)
      end

      sig { void }
      def set_current_profile
        Current.profile = current_profile! if Current.household
      end

      sig { void }
      def require_admin!
        # A kid profile has no settings, whoever signed the browser in.
        return unless require_grown_up!
        return if current_user!.admin?

        render_errors("Admin access required", status: :forbidden)
      end

      # A kid profile gets the watching, not the running (PROPOSAL §7.4).
      # False when it has refused.
      sig { returns(T::Boolean) }
      def require_grown_up!
        profile = Current.profile
        return true unless profile.is_a?(Profile) && profile.kid?

        render_errors("Not from a kid profile", status: :forbidden)
        false
      end
    end
  end
end
