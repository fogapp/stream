# typed: strict
# frozen_string_literal: true

module Playback
  # The kind of client a play was on, coarse on purpose: the browser, its
  # major version and the platform, or the Apple TV app's version.
  # What's learned is learned per
  # class, so a browser update tries everything afresh.
  module ClientClass
    extend T::Sig

    sig { params(user_agent: String).returns(String) }
    def self.from(user_agent)
      app = user_agent[%r{\AStreamTV/(\d+)}, 1]
      return "Apple TV app #{app}" if app

      name = Device.name_from(user_agent)
      browser = name.split(" on ").first.to_s
      version =
        case browser
        when "Edge" then user_agent[%r{Edg/(\d+)}, 1]
        when "Firefox" then user_agent[%r{Firefox/(\d+)}, 1]
        when "Chrome" then user_agent[%r{(?:Chrome|CriOS)/(\d+)}, 1]
        when "Safari" then user_agent[%r{Version/(\d+)}, 1]
        end
      version ? name.sub(browser, "#{browser} #{version}") : name
    end
  end
end
