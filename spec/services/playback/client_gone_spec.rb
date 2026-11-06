# typed: false
# frozen_string_literal: true

require "rails_helper"
require "socket"

RSpec.describe Playback::ClientGone do
  around do |example|
    @server = TCPServer.new("127.0.0.1", 0)
    @client = TCPSocket.new("127.0.0.1", @server.addr[1])
    @ours = @server.accept
    example.run
  ensure
    [ @client, @ours, @server ].each { |socket| socket&.close unless socket&.closed? }
  end

  it "says a client that is still connected is still there, with or without more to say" do
    expect(described_class.gone?(@ours)).to be(false)
    @client.write("GET /next HTTP/1.1\r\n")
    expect(@ours.wait_readable(1)).to be_truthy
    expect(described_class.gone?(@ours)).to be(false)
    # Peeked at, not read: the next request is all still there.
    expect(@ours.readpartial(64)).to eq("GET /next HTTP/1.1\r\n")
  end

  it "says a client that hung up has gone" do
    @client.close
    expect(@ours.wait_readable(1)).to be_truthy
    expect(described_class.gone?(@ours)).to be(true)
  end

  it "takes anything that isn't a socket as still there" do
    expect(described_class.gone?(nil)).to be(false)
    expect(described_class.gone?(StringIO.new)).to be(false)
  end
end
