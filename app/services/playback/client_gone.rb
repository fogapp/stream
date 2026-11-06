# typed: strict
# frozen_string_literal: true

module Playback
  # Whether whoever made a request has hung up on it. A player that seeks
  # drops the segment it was fetching, and Thruster drops its connection to
  # Puma with it — but the request's thread would wait out its twenty
  # seconds for the transcoder regardless, asking again for a GOP nobody
  # wants any more (Segments). The socket says so at once: readable with
  # nothing to read is the other end closed.
  module ClientGone
    extend T::Sig

    # socket: the request's own (env["puma.socket"]); anything that isn't
    # a plain socket — none at all, in a spec — is taken as still there.
    sig { params(socket: T.untyped).returns(T::Boolean) }
    def self.gone?(socket)
      return false unless socket.is_a?(BasicSocket)
      return false if socket.wait_readable(0).nil?

      # Peeked, never read: bytes there would be the connection's next request.
      waiting = socket.recv_nonblock(1, Socket::MSG_PEEK, exception: false)
      waiting.nil? || waiting == ""
    rescue IOError, SystemCallError
      true
    end
  end
end
