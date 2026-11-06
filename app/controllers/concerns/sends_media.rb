# typed: strict
# frozen_string_literal: true

# Bytes go through Thruster (CLAUDE.md invariant 7): Rails authorizes, then
# answers with X-Sendfile, so no Puma thread is held for the length of a
# file.
module SendsMedia
  extend ActiveSupport::Concern
  extend T::Sig
  extend T::Helpers

  requires_ancestor { ActionController::API }

  # The file was there when the request checked and gone when it was sent:
  # the transcoder's sweep evicted a cache directory, or a file moved. A
  # 404, not a 500 — unless the caller can make it again (a segment).
  class Gone < StandardError; end

  included do
    T.bind(self, T.class_of(ActionController::API))
    rescue_from Gone, with: :gone
  end

  private

  sig { params(path: T.any(String, Pathname), mime: String).void }
  def serve(path, mime)
    # Decided by configuration, never by a request header: Thruster in
    # production (x_sendfile_header set), nothing in front elsewhere.
    if Rails.application.config.action_dispatch.x_sendfile_header.present?
      send_file path, type: mime, disposition: "inline"
    else
      # No proxy in front (development, specs): Rack::Files answers Range
      # requests itself, so seeking still works.
      status, headers, body = Rack::Files.new(nil, {}, mime).serving(request, path.to_s)
      self.status = status
      headers.each { |key, value| response.headers[key] = value }
      response.headers["Content-Type"] = mime
      self.response_body = body
    end
  rescue ActionController::MissingFile, Errno::ENOENT => e
    raise Gone, e.message
  end

  sig { void }
  def gone = head(:not_found)
end
