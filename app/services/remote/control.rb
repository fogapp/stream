# typed: strict
# frozen_string_literal: true

module Remote
  # Playing to another screen (PROPOSAL §11 Phase 6): find the device people
  # mean ("the living room"), and hand it a command it picks up on its next
  # poll. The MCP surface and the app use the same path.
  module Control
    extend T::Sig

    class Error < StandardError; end

    # The listening device a name means: its label or browser name, exactly,
    # then as a prefix, then as a word inside it ("living room" finds
    # "Living room TV"). With no name and one device listening, that one.
    sig { params(name: T.nilable(String)).returns(Device) }
    def self.find_device(name)
      listening = Device.listening.order(:label, :name).to_a
      raise Error, "No screen is listening. Open Stream on the TV (at /tv), or turn on \"Let this browser be played to\" in Settings › Viewing." if listening.empty?

      wanted = name.to_s.strip.downcase.delete_prefix("the ")
      if wanted.empty?
        return T.must(listening.first) if listening.one?

        raise Error, "Which screen? Listening: #{listening.map(&:display_name).join(', ')}."
      end

      found = NameMatch.find(listening, wanted) { |device| [ device.label, device.name ].compact }
      found || raise(Error, "No listening screen is called \"#{name}\". Listening: #{listening.map(&:display_name).join(', ')}.")
    end

    sig do
      params(device: Device, kind: DeviceCommand::Kind, payload: T::Hash[String, T.untyped], user: T.nilable(User))
        .returns(DeviceCommand)
    end
    def self.send_command(device, kind, payload = {}, user: nil)
      DeviceCommand.create!(household_id: device.household_id, device: device, user: user, kind: kind.serialize,
        payload: payload, expires_at: DeviceCommand::LIFETIME.from_now)
    end

    # Play a title there, as a profile: the device switches to that profile
    # when it isn't watching as it already (a PIN-protected one only when
    # an admin asked).
    sig do
      params(device: Device, playable: T.any(Movie, Episode, Video, Clip, LiveStream), profile: T.nilable(Profile), user: User,
        start: T.nilable(Float)).returns(DeviceCommand)
    end
    def self.play(device, playable, profile:, user:, start: nil)
      heading = PlaybackSessionSerializer.heading(playable)
      payload = { "kind" => playable.class.name.to_s.underscore, "id" => playable.id,
                  "title" => [ heading[:title], heading[:subtitle] ].compact.join(" · "), "start" => start }.compact
      send_command(device, DeviceCommand::Kind::Play, payload.merge(as_profile(profile, user)), user: user)
    end

    # Put a Grid channel on there (PROPOSAL §7.7), as a profile.
    sig { params(device: Device, station: Station, profile: T.nilable(Profile), user: User).returns(DeviceCommand) }
    def self.tune(device, station, profile:, user:)
      payload = { "number" => station.number, "station_id" => station.id, "name" => station.name }
      send_command(device, DeviceCommand::Kind::Tune, payload.merge(as_profile(profile, user)), user: user)
    end

    # What lets the device switch to the profile, if one was named (a
    # PIN-protected one only when an admin asked).
    sig { params(profile: T.nilable(Profile), user: User).returns(T::Hash[String, String]) }
    def self.as_profile(profile, user)
      return {} if profile.nil?
      raise Error, "#{profile.name} has a PIN; only an admin can start something as them remotely." if profile.pin? && !user.admin?

      { "profile_id" => profile.id, "profile_token" => ProfileTokens.issue(profile) }
    end
    private_class_method :as_profile

    # What a device picks up on its poll: every waiting command, oldest
    # first, each handed over once.
    sig { params(device: Device).returns(T::Array[DeviceCommand]) }
    def self.collect(device)
      device.update_columns(remote_seen_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      DeviceCommand.transaction do
        commands = device.device_commands.waiting.order(:created_at).lock("FOR UPDATE SKIP LOCKED").to_a
        DeviceCommand.where(id: commands.map(&:id)).update_all(delivered_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
        commands
      end
    end

    # What's playing on a device now, from its latest live session.
    sig { params(device: Device).returns(T.nilable(PlaybackSession)) }
    def self.now_playing(device)
      device.playback_sessions.watched.where(state: PlaybackSession::State::Active.serialize).where(last_seen_at: 2.minutes.ago..)
        .order(last_seen_at: :desc).first
    end
  end
end
