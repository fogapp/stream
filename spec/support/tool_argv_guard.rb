# typed: false
# frozen_string_literal: true

# Media invariant 6 (CLAUDE.md), checked on every ffmpeg and ffprobe run
# Stream itself starts in the suite — locally, and the argv a remote
# transcoder is handed: an argv of plain strings, and each input preceded by
# its own -protocol_whitelist naming only the file protocols, the remote
# ones for a node's signed /media/n URL, or a live stream's for its address. Commands a spec runs to make its
# fixtures are its own business and aren't checked.
module ToolArgvGuard
  LOCAL = %w[file file,pipe].freeze
  REMOTE = "http,https,tcp,tls"
  # A live stream's own address (PROPOSAL §7.8, FfmpegArgs::Input.live):
  # what its scheme needs, never `file`.
  LIVE = [ "rtsp,rtsps,tcp,tls,udp,rtp,srtp", "http,https,tcp,tls,crypto" ].freeze

  def self.check!(argv)
    raise "argv must be an array of strings: #{argv.inspect}" unless argv.is_a?(Array) && argv.all?(String)

    at = argv.index { |arg| %w[ffmpeg ffprobe].include?(File.basename(arg)) }
    return if at.nil?

    options = argv.drop(at + 1)
    whitelist = nil
    options.each_with_index do |arg, index|
      whitelist = options[index + 1] if arg == "-protocol_whitelist"
      next unless arg == "-i"

      input = options[index + 1].to_s
      remote = input.start_with?("#{Playback::Runner::SERVER}/media/n/", "#{Playback::Runner::SERVER}/fog/compute/runs/")
      live = !remote && input.match?(%r{\A(rtsps?|https?)://})
      allowed = if remote then [ REMOTE ]
      elsif live then LIVE
      else LOCAL
      end
      raise "#{argv[at]} input #{input} has no -protocol_whitelist before it: #{argv.join(' ')}" if whitelist.nil?
      raise "#{argv[at]} input #{input} allows #{whitelist}: #{argv.join(' ')}" unless allowed.include?(whitelist)

      whitelist = nil # per input: the next -i needs its own
    end
  end

  def self.from_app?(locations)
    locations.any? { |location| location.path.to_s.start_with?(Rails.root.join("app").to_s) }
  end

  # On exec_argv, which every ToolRunner entry point (run, each_line) builds
  # its command with: a spy on those would have to forward their keywords
  # and block through sorbet-runtime's wrapper, which drops the keywords.
  # The first frame outside ToolRunner says whether the app asked.
  module ToolRunnerSpy
    def exec_argv(argv)
      asker = caller_locations(1, 12).find do |location|
        path = location.path.to_s
        !path.end_with?("app/services/tool_runner.rb") && !path.include?("/gems/")
      end
      ToolArgvGuard.check!(argv) if asker && ToolArgvGuard.from_app?([ asker ])
      super
    end
  end

  module RunnerSpy
    def spawn_local(argv, ...)
      ToolArgvGuard.check!(argv)
      super
    end

    def start_remote(...)
      super.tap { |handle| ToolArgvGuard.check!(TranscodeRun.find(handle.run_id).argv) }
    end
  end
end

RSpec.configure do |config|
  config.before(:suite) do
    ToolRunner.singleton_class.prepend(ToolArgvGuard::ToolRunnerSpy)
    Playback::Runner.singleton_class.prepend(ToolArgvGuard::RunnerSpy)
  end
end
