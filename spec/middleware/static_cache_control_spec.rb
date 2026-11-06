# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Middleware::StaticCacheControl do
  let(:year) { "public, max-age=#{1.year.to_i}" }

  def cache_control(path, served_with: year)
    downstream = ->(_env) { [ 200, { "cache-control" => served_with }, [ "" ] ] }
    _status, headers, _body = described_class.new(downstream, static_cache_control: year).call("PATH_INFO" => path)
    headers["cache-control"]
  end

  it "sits in front of the file server" do
    stack = Rails.application.middleware.map(&:klass)
    expect(stack.index(described_class)).to eq(stack.index(ActionDispatch::Static) - 1)
  end

  it "makes the shell revalidate every load, however it's asked for" do
    expect(cache_control("/")).to eq("no-cache")
    expect(cache_control("/index.html")).to eq("no-cache")
  end

  it "keeps a year on the content-hashed bundles" do
    expect(cache_control("/assets/index-CQ6fXOxS.js")).to eq(year)
  end

  it "gives the other unhashed files an hour" do
    expect(cache_control("/sw.js")).to eq("public, max-age=3600")
    expect(cache_control("/manifest.webmanifest")).to eq("public, max-age=3600")
  end

  it "leaves responses the file server didn't produce alone" do
    rails_default = "max-age=0, private, must-revalidate"
    expect(cache_control("/settings", served_with: rails_default)).to eq(rails_default)
  end
end
