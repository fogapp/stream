# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Pressing Play (PROPOSAL §6.2): the client says what it can decode, the
    # decision engine picks the file and the cheapest path, and the answer is
    # either the original file or a stream the transcoder is already warming.
    class PlaybackSessionsController < BaseController
      finds :playback_session, from: -> { PlaybackSession.all }
      skip_before_action :set_playback_session, only: %i[create readable]
      # A guest may watch (ACCESS.md › Roles): start a session, tune and
      # leave a channel, and end it — only ever their own. Progress and the
      # player's events go to /media/s/:token, which the session's own token
      # authorizes.
      skip_before_action :deny_guest_writes, only: %i[create watch standby destroy fallback upgrade]
      before_action :require_own_session_for_guest, only: %i[watch standby destroy fallback upgrade]

      # How often pressing Play on a device updates when it was last seen.
      DEVICE_SEEN_EVERY = T.let(5.minutes, ActiveSupport::Duration)

      sig { void }
      def create
        tuning = Stations::Tuning.new(station_id: params[:station_id].to_s.presence, airing_id: params[:airing_id].to_s.presence,
          after_airing_id: params[:after_airing_id].to_s.presence, standby: standby?)
        stream = tuning.stream
        return create_live(stream, upsert_device) if stream

        airing = tuning.airing
        playable = airing ? T.cast(airing.playable, T.any(Movie, Episode, Extra, Video, LiveStream)) : find_playable
        device = upsert_device
        # A team's game on a Grid channel plays its stream, and keeps its slot.
        return create_live(playable, device, airing: airing) if playable.is_a?(LiveStream)

        create_file(playable, device, airing)
      rescue Stations::Tuning::Refused => e
        response.headers["Retry-After"] = e.retry_after.to_s if e.retry_after
        render_errors(e.message, status: :conflict)
      end

      # Whether a title can still be played, asked before the corner offers
      # to resume it: a title purged since it was left is not found, and one
      # whose files have all gone has none readable. Nothing is decided.
      sig { void }
      def readable
        playable = T.cast(Viewing::Playables.find!(params.require(:playable_type), params.require(:playable_id),
          only: %w[movie episode extra video clip]), T.any(Movie, Episode, Extra, Video, Clip))
        render json: { readable: playable.media_files.playable.exists? }
      end

      # A channel tuned ahead is now the one on screen: from here it's a play
      # like any other, joined where the viewer came in.
      sig { void }
      def watch
        position = params[:position].presence&.to_f || playback_session.position_seconds
        if playback_session.standby
          playback_session.update!(standby: false, started_at: Time.current, last_seen_at: Time.current, joined_at_seconds: position)
          PlaybackEvent.create!(playback_session: playback_session, kind: PlaybackEvent::Kind::Start.serialize, position_seconds: position,
            created_at: Time.current)
        end
        head :no_content
      end

      # Changed away from, and kept tuned for Last (PROPOSAL §7.7): the play
      # stops here, but the channel stays ready to switch back to. Ending it
      # would leave the one behind Last playing nothing.
      #
      # Asked again of a channel already on standby, it's the deck saying
      # the channel is still held (docs/APPLETV_STALLS.md › R3): seen now,
      # so its run is kept (Supervisor#stop_idle) and the session isn't
      # ended as abandoned. A prerolled player fetches nothing for minutes.
      sig { void }
      def standby
        if playback_session.standby
          playback_session.update_columns(last_seen_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
        else
          position = params[:position].presence&.to_f || playback_session.position_seconds
          playback_session.update!(standby: true, position_seconds: position, last_seen_at: Time.current)
          PlaybackEvent.create!(playback_session: playback_session, kind: PlaybackEvent::Kind::Stop.serialize, position_seconds: position,
            created_at: Time.current)
        end
        head :no_content
      end

      sig { void }
      def destroy
        playback_session.end!
        head :no_content
      end

      # The play failed: what the player or
      # the transcoder saw is recorded on this session, it ends, and the play
      # carries on as a new one a rung down the ladder (Playback::Fallback),
      # from where it got to. A 409 when there's no rung left, saying what
      # was tried. Asked twice, it answers with the same new session.
      sig { void }
      def fallback
        failed = playback_session
        file = failed.media_file
        return render_errors("A live stream has nowhere lower to go", status: :conflict) if file.nil?

        existing = failed.fallback
        # The session a fallback already made, answered again.
        return render(json: session_json(existing, existing.position_seconds), status: :ok) if existing

        failure = PlaybackSession::FailureClass.try_deserialize(params[:failure_class].to_s) || PlaybackSession::FailureClass::Unsupported
        position = params[:position].presence&.to_f || failed.position_seconds
        Playback::Fallback.record!(failed, failure, position: position, reported: params[:cause].to_s.first(300).presence)

        chain = failed.chain
        lower = chain.count(&:failure_class) <= Playback::Fallback::LIMIT ? Playback::Fallback.descend(failed, file, failure) : nil
        return render_errors(Playback::Fallback.given_up(chain, failed.device_name || "this browser"), status: :conflict) if lower.nil?

        decision = lower.decision
        return render_errors(busy_message, status: :conflict) if decision.nil?

        # An upgrade that failed goes back to where it came from, and stays.
        transient = Playback::Fallback.passing?(failed, failure) && !failed.stored_decision.upgrade?
        carry_on(failed, file, decision, lower.node, position,
          "fallback" => { "from" => failed.method, "failure" => failure.serialize, "transient" => transient })
      end

      # A play that fell back for a passing reason (a stall, the network)
      # climbs back to the rung it fell from, when the player says it's a
      # good moment (R2, "Upgrading back"). 204 when there's nothing better.
      sig { void }
      def upgrade
        lower = playback_session
        file = lower.media_file
        decision = file ? Playback::Fallback.upgrade(lower, file) : nil
        return head(:no_content) if file.nil? || decision.nil?

        position = params[:position].presence&.to_f || lower.position_seconds
        lower.update!(position_seconds: position)
        lower.end!
        carry_on(lower, file, decision, nil, position,
          "upgrade" => { "from" => lower.method, "constraints" => lower.constraints.to_h })
      end

      private

      # A file played, or tuned to on a channel. A channel this profile may
      # see airs only what it may see (Viewing::Access.stations): checked
      # once when tuning to one, and a title asked for by id is checked as
      # it's found.
      sig { params(playable: T.any(Movie, Episode, Extra, Video, Clip), device: T.nilable(Device), airing: T.nilable(Airing)).void }
      def create_file(playable, device, airing)
        client = client_of(device)
        max_height = Playback::Encoders.max_height
        wanted = airing&.media_file_id || params[:media_file_id].presence&.to_s ||
          watch_state_of(playable)&.media_file_id
        choice = T.let(ActiveSupport::Notifications.instrument("decide.stream") do
          Playback::Start.choose(playable, client, max_height, wanted: wanted)
        end, T.nilable([ MediaFile, Playback::Decision ]))
        return render_errors("There's no readable file for this yet", status: :conflict) if choice.nil?

        file, chosen = choice
        return render_errors(T.must(chosen.refusal)) unless chosen.playable?

        placed = Playback::Start.place(file, chosen, client, max_height)
        decision = placed.decision
        return render_errors(busy_message, status: :conflict) if decision.nil?
        return refuse_tuning_ahead if tuned_ahead_conversion?(decision)

        start_at = airing ? start_of(airing) : start_position(playable)
        session = Playback::Start.file(decision, position: start_at, live: (!airing.nil?).to_s, attributes: new_session(playable, device, airing).merge(
          joined_at_seconds: airing ? start_at : nil, media_file: file, transcode_node: placed.node,
          playlist: Playlist.find_by(profile: current_profile!, id: params[:playlist_id].to_s.presence), adaptive: adaptive?,
          segment_target_ms: Playback::SegmentPlan::TARGET_MS, client_class: client_class, start_position_seconds: start_at
        ))
        json = T.let(ActiveSupport::Notifications.instrument("serialize.stream") { session_json(session, start_at) },
          T::Hash[Symbol, T.untyped])
        render json: json, status: :created
      end

      # A camera or web stream (PROPOSAL §7.8): decided from the tracks its
      # probe saw, always relayed. A game on a Grid channel carries its
      # airing, so the player knows when its slot ends and what follows.
      sig { params(stream: LiveStream, device: T.nilable(Device), airing: T.nilable(Airing)).void }
      def create_live(stream, device, airing: nil)
        # A team's MLB.tv stream is read the first time it plays, and again
        # once a game went off: what it carries is only known then.
        begin
          LiveStreams::Prober.call(stream) if stream.team? && (stream.probed_at.nil? || !stream.online?)
        rescue LiveStreams::Prober::Failure => e
          return render_errors(e.message)
        end
        client = client_of(device)
        decide = lambda do |height|
          Playback::Decision.live(stream, client.capabilities, audio_index: client.audio_index, max_height: height, device_name: client.device_name)
        end
        chosen = decide.call(Playback::Encoders.max_height)
        return render_errors(T.must(chosen.refusal)) unless chosen.playable?

        decision = Playback::Budget.fit(chosen) { |smaller| decide.call(smaller) }
        return render_errors(busy_message, status: :conflict) if decision.nil?
        return refuse_tuning_ahead if tuned_ahead_conversion?(decision)

        session = Playback::Start.stream(decision, attributes: new_session(stream, device, airing).merge(
          segment_target_ms: Playback::LiveArgs::SEGMENT_SECONDS * 1000
        ))
        render json: session_json(session, 0.0), status: :created
      end

      # The play, carried on from another session of it: the same title,
      # file, device and list, from where it got to.
      sig do
        params(from: PlaybackSession, file: MediaFile, decision: Playback::Decision, node: T.nilable(TranscodeNode), position: Float,
          note: T::Hash[String, T.untyped]).void
      end
      def carry_on(from, file, decision, node, position, note)
        session = Playback::Start.file(decision, position: position, live: (!from.airing_id.nil?).to_s, note: note, announce: false, attributes: {
          fallback_from: from, profile_id: from.profile_id, user_id: from.user_id, playable: from.playable, media_file: file,
          device_id: from.device_id, transcode_node: node, playlist_id: from.playlist_id, airing_id: from.airing_id,
          joined_at_seconds: from.joined_at_seconds, device_name: from.device_name, adaptive: from.adaptive,
          segment_target_ms: Playback::SegmentPlan::TARGET_MS, position_seconds: position, client_class: from.client_class,
          start_position_seconds: position
        })
        render json: session_json(session, position), status: :created
      end

      sig { params(session: PlaybackSession, resume_at: Float).returns(T::Hash[Symbol, T.untyped]) }
      def session_json(session, resume_at)
        PlaybackSessionSerializer.session_json(session, token: Playback::StreamToken.issue(session), resume_at: resume_at)
      end

      # What any new play starts with.
      sig do
        params(playable: T.any(Movie, Episode, Extra, Video, Clip, LiveStream), device: T.nilable(Device), airing: T.nilable(Airing))
          .returns(T::Hash[Symbol, T.untyped])
      end
      def new_session(playable, device, airing)
        { airing: airing, standby: standby?, profile: current_profile!, user: current_user!, playable: playable, device: device,
          device_name: device&.name || Device.name_from(request.user_agent.to_s) }
      end

      # What this press of Play can take and asks for.
      sig { params(device: T.nilable(Device)).returns(Playback::Start::Client) }
      def client_of(device)
        Playback::Start::Client.new(capabilities: device&.capability_profile || Playback::Capabilities.from_json(params[:capabilities]&.to_unsafe_h),
          device_name: device&.name || "This browser", client_class: client_class, audio_index: params[:audio_index].presence&.to_i,
          burn_subtitle: params[:burn_subtitle].presence&.to_i)
      end

      # Tuned ahead only when it's cheap: a conversion waits to be watched.
      sig { params(decision: Playback::Decision).returns(T::Boolean) }
      def tuned_ahead_conversion?(decision) = standby? && decision.method == PlaybackSession::Method::VideoTranscode

      sig { void }
      def refuse_tuning_ahead
        render_errors("This channel needs converting, so it isn't tuned ahead", status: :conflict)
      end

      # The kind of client asking (Playback::ClientClass).
      sig { returns(String) }
      def client_class = Playback::ClientClass.from(request.user_agent.to_s)

      sig { void }
      def require_own_session_for_guest
        return unless current_user!.guest?
        return if playback_session.user_id == current_user!.id

        render_errors("Guests have read-only access", status: :forbidden)
      end

      sig { returns(T.any(Movie, Episode, Extra, Video, Clip, LiveStream)) }
      def find_playable
        T.cast(Viewing::Playables.find!(params.require(:playable_type), params.require(:playable_id),
          only: %w[movie episode extra video clip live_stream]), T.any(Movie, Episode, Extra, Video, Clip, LiveStream))
      end

      # The browser's profile, stored against the device it came from so the
      # transcode report can ask it again later.
      sig { returns(T.nilable(Device)) }
      def upsert_device
        key = params[:device_key].to_s.first(64)
        return nil if key.blank?

        device = Device.find_or_initialize_by(client_key: key)
        device.name = Device.name_from(request.user_agent.to_s) if device.new_record? || device.name.blank?
        device.capabilities = Playback::Capabilities.from_json(params[:capabilities]&.to_unsafe_h).to_json_hash
        seen = device.last_seen_at
        device.last_seen_at = Time.current if seen.nil? || seen < DEVICE_SEEN_EVERY.ago
        # Written only when something changed: most presses of Play change nothing.
        device.save! if device.changed?
        device
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
        # Made by another request from this browser a moment ago (its remote
        # listener, say): use that one.
        existing = Device.find_by(client_key: key)
        raise if existing.nil?

        existing.update!(capabilities: Playback::Capabilities.from_json(params[:capabilities]&.to_unsafe_h).to_json_hash, last_seen_at: Time.current)
        existing
      end

      sig { returns(T::Boolean) }
      def standby? = bool_param(:standby)

      # Smaller versions to drop to (Playback::Variants): when the browser
      # asks, or the request comes from outside the household's network.
      sig { returns(T::Boolean) }
      def adaptive?
        return true if bool_param(:abr)

        address = IPAddr.new(request.remote_ip.to_s)
        !(address.private? || address.loopback? || address.link_local?)
      rescue IPAddr::InvalidAddressError
        false
      end

      sig { returns(String) }
      def busy_message
        cap = Playback::Placement.capacity
        "#{cap == 1 ? 'Another video is' : "#{cap} videos are"} already being converted, which is all this server " \
          "can do at once, even made smaller. Try again when #{cap == 1 ? 'it finishes' : 'one finishes'}, or raise the limit in Settings."
      end

      sig { params(airing: Airing).returns(Float) }
      def start_of(airing)
        Stations::Tuning.start_of(airing, start: params[:start].presence&.to_f, behind: params[:behind].presence&.to_f)
      end

      sig { params(playable: T.any(Movie, Episode, Extra, Video, Clip)).returns(Float) }
      def start_position(playable)
        explicit = params[:start].presence&.to_f
        return explicit if explicit

        state = watch_state_of(playable)
        state.nil? || state.completed? ? 0.0 : state.position_seconds
      end

      # This profile's state of what's being played, read once a request
      # (which file it was on, and where it got to).
      sig { params(playable: T.any(Movie, Episode, Extra, Video, Clip)).returns(T.nilable(WatchState)) }
      def watch_state_of(playable)
        @watch_states ||= T.let({}, T.nilable(T::Hash[[ String, String ], T.nilable(WatchState)]))
        key = [ playable.class.polymorphic_name, playable.id.to_s ]
        return @watch_states[key] if @watch_states.key?(key)

        @watch_states[key] = WatchState.find_by(profile: current_profile!, playable: playable)
      end
    end
  end
end
