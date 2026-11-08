# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Playing to another screen, from the screen's side and the sender's
    # (PROPOSAL §11 Phase 6). A browser that lets itself be played to polls
    # `commands`; anything signed in can send it one. The MCP surface sends
    # through the same Remote::Control.
    class RemoteController < BaseController
      # This browser: what it's called and whether it can be played to.
      sig { void }
      def this_device
        device = T.must(current_device(create: true))
        if request.patch?
          device.label = params[:label].to_s.strip.first(60).presence if params.key?(:label)
          device.remote_control = bool_param(:remote_control) if params.key?(:remote_control)
          device.save!
        end
        render json: DeviceSerializer.remote_json(device)
      end

      # The poll: commands waiting for this browser, each handed over once.
      sig { void }
      def commands
        device = current_device(create: true)
        return render(json: []) if device.nil? || !device.remote_control

        render json: Remote::Control.collect(device).map { |command| { id: command.id, kind: command.kind_enum, payload: command.payload } }
      end

      # Screens listening now, besides this one.
      sig { void }
      def devices
        mine = current_device&.id
        screens = Device.listening.order(:label, :name)
        screens = screens.where.not(id: mine) if mine
        render json: DeviceSerializer.remote_index(screens.to_a)
      end

      sig { void }
      def send_command
        device = Device.listening.find(params.require(:id))
        kind = DeviceCommand::Kind.try_deserialize(params.require(:kind).to_s)
        return render_errors("Unknown command") if kind.nil?

        command =
          if kind == DeviceCommand::Kind::Play
            playable = find_playable
            Remote::Control.play(device, playable, profile: current_profile!, user: current_user!)
          else
            Remote::Control.send_command(device, kind, params.permit(:seconds, :by).to_h.transform_values(&:to_f), user: current_user!)
          end
        render json: { id: command.id, kind: command.kind_enum }, status: :created
      rescue Remote::Control::Error => e
        render_errors(e.message)
      end

      private

      sig { returns(T.any(Movie, Episode, Video, Clip, LiveStream)) }
      def find_playable
        T.cast(Viewing::Playables.find!(params.require(:playable_type), params.require(:playable_id),
          only: %w[movie episode video clip live_stream]), T.any(Movie, Episode, Video, Clip, LiveStream))
      end
    end
  end
end
