# typed: strict
# frozen_string_literal: true

module Mcp
  # The tool catalog. Deterministic order: tools/list is part of every
  # client's prompt-cache prefix, and a reshuffled catalog invalidates it.
  module Toolbox
    extend T::Sig

    ALL = T.let([
      Mcp::Tools::Whoami,
      Mcp::Tools::Search,
      Mcp::Tools::NextUp,
      Mcp::Tools::ListScreens,
      Mcp::Tools::PlayOnScreen,
      Mcp::Tools::ControlScreen,
      Mcp::Tools::NowPlaying,
      Mcp::Tools::AddToWatchLater,
      Mcp::Tools::MarkWatched,
      Mcp::Tools::WhatsOn,
      Mcp::Tools::LiveStreams,
      Mcp::Tools::TuneChannel
    ].freeze, T::Array[T.class_of(Mcp::Tools::Base)])

    # The tools a token may use: a read-scoped token gets only the ones that
    # look (Mcp::Tools::Base.read_only?), in the same order.
    sig { params(token: ApiToken).returns(T::Array[T.class_of(Mcp::Tools::Base)]) }
    def self.for(token)
      token.read_only? ? ALL.select(&:read_only?) : ALL
    end

    # Whether a tool by this name changes something — false for a reader and
    # for a name that is no tool at all.
    sig { params(name: String).returns(T::Boolean) }
    def self.writer?(name)
      tool = ALL.find { |candidate| candidate.name_value == name }
      !tool.nil? && !tool.read_only?
    end
  end
end
