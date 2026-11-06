# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Notifications", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household) }
  let(:other) { create_user(household: household) }

  before do
    Notifier.notify(users: [ user ], kind: "source_failed", title: "X is failing", dedupe_key: "sf:1")
    Notifier.notify(users: [ other ], kind: "source_failed", title: "X is failing", dedupe_key: "sf:1")
  end

  it "lists only the current user's notifications with an unread count" do
    get "/api/v1/notifications", headers: auth_headers(user)
    expect(json["unread_count"]).to eq(1)
    expect(json["notifications"].length).to eq(1)
    expect(json["notifications"].first["title"]).to eq("X is failing")
  end

  it "pages newest first and still answers the count on a short page" do
    Notifier.notify(users: [ user ], kind: "want_fulfilled", title: "Piranesi is on your shelf", dedupe_key: "wf:1")
    get "/api/v1/notifications", params: { per: 1 }, headers: auth_headers(user)
    expect(json["unread_count"]).to eq(2)
    expect(json["notifications"].map { |row| row["title"] }).to eq([ "Piranesi is on your shelf" ])
    expect(response.headers["X-Total-Count"]).to eq("2")
  end

  it "marks one notification read, once" do
    id = user.notifications.first.id
    post "/api/v1/notifications/#{id}/read", headers: auth_headers(user)
    expect(json["read_at"]).to be_present
    expect(json["unread_count"]).to eq(0)

    first_read = 1.hour.ago
    user.notifications.first.update!(read_at: first_read)
    post "/api/v1/notifications/#{id}/read", headers: auth_headers(user)
    expect(user.notifications.first.read_at).to be_within(1.second).of(first_read)
  end

  it "will not mark another user's notification read" do
    post "/api/v1/notifications/#{other.notifications.first.id}/read", headers: auth_headers(user)
    expect(response).to have_http_status(:not_found)
    expect(other.notifications.unread.count).to eq(1)
  end

  it "marks everything read at once, for this user only" do
    Notifier.notify(users: [ user ], kind: "want_fulfilled", title: "Piranesi is on your shelf", dedupe_key: "wf:1")
    post "/api/v1/notifications/read_all", headers: auth_headers(user)
    expect(json["unread_count"]).to eq(0)
    expect(user.notifications.unread.count).to eq(0)
    expect(other.notifications.unread.count).to eq(1)
  end
end
