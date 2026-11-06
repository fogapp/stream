# typed: false
# frozen_string_literal: true

# Media invariant 7 (CLAUDE.md): what Thruster sees. The test app has no
# sendfile header configured, so this runs one request through the whole app
# the way production is set up — x_sendfile_header set, Rack::Sendfile in
# front — and returns the Rack response, whose X-Sendfile header names the
# file and whose body is empty when no Puma thread carried the bytes.
module ThrusterHelpers
  def through_thruster(path, headers = {})
    allow(Rails.application.config.action_dispatch).to receive(:x_sendfile_header).and_return("X-Sendfile")
    env = headers.transform_keys { |key| "HTTP_#{key.upcase.tr('-', '_')}" }
    Rack::MockRequest.new(Rack::Sendfile.new(Rails.application, "X-Sendfile")).get(path, env)
  end

  def expect_sent_by_thruster(path, file, headers = {})
    thruster = through_thruster(path, headers)
    expect(thruster.status).to be_in([ 200, 206 ])
    expect(thruster.headers["x-sendfile"]).to eq(File.realpath(file.to_s)).or eq(file.to_s)
    expect(thruster.body).to be_empty
  end
end

RSpec.configure do |config|
  config.include ThrusterHelpers
end
