# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Invites", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let(:member) { create_user(household: household) }

  describe "POST /api/v1/invites" do
    it "lets an admin mint an invite" do
      post "/api/v1/invites", headers: auth_headers(admin)
      expect(response).to have_http_status(:created)
      expect(json["code"]).to be_present
      expect(json["role"]).to eq("member")
    end

    it "forbids non-admins" do
      post "/api/v1/invites", headers: auth_headers(member)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /api/v1/invites/accept" do
    let(:invite) { InviteCode.generate!(household: household, created_by: admin) }

    it "creates a member in the inviting household" do
      post "/api/v1/invites/accept", params: {
        code: invite.code, email: "new@example.com", name: "New", password: "passwordpassword"
      }
      expect(response).to have_http_status(:created)
      new_user = User.find_by(email: "new@example.com")
      expect(new_user.household_id).to eq(household.id)
      expect(new_user.role).to eq("member")
      expect(invite.reload.used_at).to be_present
    end

    it "rejects a consumed invite" do
      invite.consume!
      post "/api/v1/invites/accept", params: {
        code: invite.code, email: "n@example.com", name: "N", password: "passwordpassword"
      }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects an expired invite" do
      invite.update!(expires_at: 1.minute.ago)
      post "/api/v1/invites/accept", params: {
        code: invite.code, email: "n@example.com", name: "N", password: "passwordpassword"
      }
      expect(response).to have_http_status(:unprocessable_content)
    end

    # An invite is a household-admission credential: two concurrent accepts
    # both pass usable?, so the single use must be claimed by the database.
    it "admits exactly one user when two requests race the same code" do
      stale = InviteCode.find(invite.id) # both requests loaded it unused
      invite.consume!

      expect { stale.consume! }.to raise_error(InviteCode::AlreadyUsed)

      post "/api/v1/invites/accept", params: {
        code: invite.code, email: "n@example.com", name: "N", password: "passwordpassword"
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(User.where(email: "n@example.com")).not_to exist
    end

    it "rolls the loser's user back when the race is lost mid-transaction" do
      allow_any_instance_of(InviteCode).to receive(:usable?).and_return(true)
      invite.update!(used_at: Time.current) # the other request won after our check

      post "/api/v1/invites/accept", params: {
        code: invite.code, email: "n@example.com", name: "N", password: "passwordpassword"
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(User.where(email: "n@example.com")).not_to exist
      expect(ApiSession.count).to eq(0)
    end
  end
end
