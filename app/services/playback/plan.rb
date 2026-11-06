# typed: strict
# frozen_string_literal: true

module Playback
  # One file decided for one client — again as it becomes clear where a
  # conversion runs and how tall it can be. What doesn't change between
  # those decisions (the client, the sound, a drawn-in subtitle, what's
  # ruled out and why) is held here once; `decide` takes the height.
  class Plan
    extend T::Sig

    # A decision placed and fitted: where its conversion runs, and nil
    # when even a smaller conversion won't fit the limit (busy).
    class Placed < T::Struct
      const :decision, T.nilable(Decision)
      const :node, T.nilable(TranscodeNode), default: nil
    end

    sig do
      params(file: MediaFile, capabilities: Capabilities, audio_index: T.nilable(Integer), device_name: String,
        burn_subtitle: T.nilable(Integer), constraints: Constraints, fell_back: T.nilable(String)).void
    end
    def initialize(file, capabilities, audio_index:, device_name:, burn_subtitle:, constraints:, fell_back:)
      @file = file
      @capabilities = capabilities
      @audio_index = audio_index
      @device_name = device_name
      @burn_subtitle = burn_subtitle
      @constraints = constraints
      @fell_back = fell_back
    end

    # A session's file again, under other constraints: the same client,
    # sound and drawn-in subtitle it had.
    sig { params(session: PlaybackSession, file: MediaFile, constraints: Constraints, fell_back: T.nilable(String)).returns(Plan) }
    def self.again(session, file, constraints, fell_back)
      new(file, Capabilities.from_json(session.stored_decision.capabilities), audio_index: session.audio_stream_index,
        device_name: session.device_name || "This browser", burn_subtitle: session.burned_subtitle, constraints: constraints, fell_back: fell_back)
    end

    sig { params(height: Integer).returns(Decision) }
    def decide(height)
      Decision.new(@file, @capabilities, audio_index: @audio_index, max_height: height, device_name: @device_name,
        burn_subtitle: @burn_subtitle, constraints: @constraints, fell_back: @fell_back)
    end

    # Decided at `height` (or `first`, already decided there), then — for a
    # video conversion, when `place` — put where it runs, which decides how
    # tall it can be (docs/PERF_PROPOSAL.md › P5); past the limit it's made
    # smaller rather than refused (PROPOSAL §6.3).
    sig { params(height: Integer, place: T::Boolean, first: T.nilable(Decision)).returns(Placed) }
    def place_and_fit(height, place: true, first: nil)
      decision = first || decide(height)
      node = T.let(nil, T.nilable(TranscodeNode))
      if place && decision.method == PlaybackSession::Method::VideoTranscode
        node = Placement.node_for_video
        placed = node ? Encoders.max_height_for(node.encoder_kind) : height
        decision = decide(placed) if placed != height
      end
      fitted = Budget.fit(decision) { |smaller| decide(smaller) }
      Placed.new(decision: fitted, node: fitted && node)
    end
  end
end
