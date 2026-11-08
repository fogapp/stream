# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Middleware::InlineHtml do
  let(:public_dir) { Pathname(Dir.mktmpdir) }
  let(:shell) { public_dir.join("index.html") }
  let(:not_found) { ->(_env) { [ 404, {}, [ "" ] ] } }

  before { shell.write(%(<!doctype html><html><head><title>Stream</title></head><body><div id="root"></div></body></html>)) }
  after { FileUtils.rm_rf(public_dir) }

  # The file server behind Rack::Sendfile, as production runs it.
  def sendfile(app = ActionDispatch::Static.new(not_found, public_dir.to_s))
    Rack::Sendfile.new(app, "X-Sendfile")
  end

  it "sits between the glass agent and Rack::Sendfile" do
    stack = Rails.application.middleware.map(&:klass)
    expect(stack.index(described_class)).to eq(stack.index(Rack::Sendfile) - 1)
    expect(stack.index(Glass::Middleware)).to be < stack.index(described_class)
  end

  it "answers `/` with the shell itself, not an X-Sendfile header" do
    status, headers, body = described_class.new(sendfile).call(Rack::MockRequest.env_for("/"))

    expect(status).to eq(200)
    expect(headers).not_to have_key("x-sendfile")
    html = body.to_enum(:each).to_a.join
    expect(html).to eq(shell.binread)
    expect(headers["content-length"]).to eq(html.bytesize.to_s)
  end

  # The 502 of 2026-09-30: the agent wrote its tag into the empty body
  # Rack::Sendfile left, and Thruster's file didn't fit that length.
  it "lets the glass agent inject its tag into the whole page" do
    status, headers, body = Glass::Relay.inject(Rack::MockRequest.env_for("/"),
      described_class.new(sendfile).call(Rack::MockRequest.env_for("/")))

    html = body.to_enum(:each).to_a.join
    expect(status).to eq(200)
    expect(html).to include(%(<script defer src="/_glass/glass.js"></script>), '<div id="root">')
    expect(headers["content-length"]).to eq(html.bytesize.to_s)
  end

  it "leaves media handed to Thruster alone" do
    media = ->(_env) { [ 200, { "content-type" => "video/mp4", "x-sendfile" => "/media/movies/a.mp4" }, [] ] }
    _status, headers, _body = described_class.new(media).call({})

    expect(headers["x-sendfile"]).to eq("/media/movies/a.mp4")
  end
end
