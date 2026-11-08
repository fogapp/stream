# typed: strict
# frozen_string_literal: true

module Plex
  # Settings › Import from Plex's Test button (PROPOSAL §7.4): asks the
  # server who it is and what it holds, refreshes who's in the Plex Home, and
  # records how it went on the connection.
  class ConnectionCheck
    extend T::Sig

    sig { params(connection: PlexConnection).void }
    def initialize(connection)
      @connection = connection
    end

    sig { returns([ T::Boolean, String ]) }
    def call
      server = Server.for(@connection)
      identity = server.identity
      sections = server.sections.count { |section| %w[movie show].include?(section["type"]) }
      @connection.update!(machine_identifier: identity["machineIdentifier"],
        server_name: identity["friendlyName"].presence || @connection.server_name)
      users = refresh_users
      message = "Connected to #{@connection.server_name || 'Plex'}: #{sections} movie and TV libraries, #{users} Plex user#{users == 1 ? '' : 's'}."
      @connection.record_test!(true, message)
      [ true, message ]
    rescue UpstreamHttpClient::Error => e
      @connection.record_test!(false, e.message)
      [ false, e.message ]
    end

    private

    sig { returns(Integer) }
    def refresh_users
      account = Account.new(token: @connection.token.to_s, client_id: @connection.household_id)
      users = begin
        account.home_users
      rescue UpstreamHttpClient::Error
        # A server-only token (no plex.tv account behind it): just its owner.
        [ Account::HomeUser.new(id: "owner", uuid: nil, name: "Plex owner", admin: true, protected: false) ]
      end
      users.each do |user|
        mapping = @connection.plex_user_mappings.find_or_initialize_by(plex_user_id: user.id)
        first_time = mapping.new_record?
        mapping.assign_attributes(plex_uuid: user.uuid, plex_name: user.name, plex_admin: user.admin)
        # The owner's history lands in the default profile unless someone says otherwise.
        mapping.profile = Profile.default_for(T.must(@connection.household)) if first_time && user.admin
        mapping.save!
      end
      users.size
    end
  end
end
