# typed: false
# frozen_string_literal: true

require "rails_helper"
require "rake"

# Sign in with fog (fog:docs/signin-proposal.md §15). The protocol is the
# vendored fog-client's, tested there against tokens fog signed; these specs
# hold Stream's half: what a verified identity does to Stream's accounts and
# sessions, and when Stream stops offering its own sign-in.
RSpec.describe "Sign in with fog", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:issuer) { "https://fog.home.test" }
  let(:oidc_env) do
    ENV.to_h.merge("OIDC_ISSUER" => issuer, "OIDC_CLIENT_ID" => "stream", "OIDC_CLIENT_SECRET" => "s3cret")
  end
  let(:binding_cookie) { "browser-binding" }

  def identity(subject: "person:H/KIM", role: "member", handle: "kim", sid: "sid-1", email: nil)
    FogClient::Signin::Identity.new(issuer: issuer, subject: subject, handle: handle, name: handle.capitalize,
                                    email: email, roles: [ role ], sid: sid, amr: [ "pop", "user" ])
  end

  # The provider answers through the shared flow; stand it in.
  def returns(id, return_to: "/library/x")
    allow_any_instance_of(FogClient::Signin::Flow).to receive(:finish).and_return([ id, return_to ])
  end

  def fragment(location)
    URI.decode_www_form(URI(location).fragment.to_s).to_h
  end

  def callback!
    cookies[FogClient::Signin::Rails::COOKIE] = binding_cookie
    get "/auth/oidc/callback", params: { code: "c", state: "s" }
  end

  # The callback binds a pending link to this browser (__Host-fog_link); the
  # test client keeps no Secure cookie over http, so carry it by hand like
  # the start's binding.
  def keep_link_cookie!
    cookies[FogClient::Signin::Rails::LINK_COOKIE] = response.cookies.fetch(FogClient::Signin::Rails::LINK_COOKIE)
  end

  def handoff!(code)
    post "/api/v1/handoff", params: { handoff: code }
  end

  def signed_in_via_fog!(id)
    returns(id)
    callback!
    handoff!(fragment(response.location)["handoff"])
    expect(response).to have_http_status(:created)
    json
  end

  before { stub_const("ENV", oidc_env) }

  it "is not there off any provider" do
    stub_const("ENV", ENV.to_h.except("OIDC_ISSUER", "OIDC_CLIENT_ID", "OIDC_CLIENT_SECRET"))
    get "/auth/oidc/start"
    expect(response).to have_http_status(:not_found)
    get "/api/v1/setup"
    expect(json["signin"]).to eq("enabled" => false, "fog_only" => false)
  end

  it "starts by sending the browser to the provider, bound to it by a cookie" do
    start = FogClient::Signin::Flow::Start.new(url: "#{issuer}/oauth2/authorize?client_id=stream&request_uri=x", binding: "b")
    allow_any_instance_of(FogClient::Signin::Flow).to receive(:start) do |_, **kw|
      expect(kw[:return_to]).to eq("/")
      start
    end
    get "/auth/oidc/start", params: { return_to: "//evil.example/" }
    expect(response).to redirect_to(start.url)
    expect(response.headers["Set-Cookie"]).to include("__Host-fog_signin=b").and include("secure").and include("httponly")
  end

  it "sends a callback that does not verify back to the sign-in page, saying so" do
    callback!
    expect(response).to redirect_to("http://www.example.com/login#signin_error=failed")
    expect(User.count).to eq(0)
  end

  it "says when the person or fog said no" do
    allow_any_instance_of(FogClient::Signin::Flow).to receive(:finish).and_raise(FogClient::Signin::Denied.new("access_denied"))
    callback!
    expect(response).to redirect_to("http://www.example.com/login#signin_error=access_denied")
  end

  it "makes the first person on a fresh Stream its admin: fog's sign-in is the setup wizard" do
    body = signed_in_via_fog!(identity(role: "admin", handle: "alex", subject: "person:H/ALEX"))
    user = User.find(body.dig("user", "id"))
    expect(user).to be_admin
    expect(user.identities.pluck(:issuer, :subject)).to eq([ [ issuer, "person:H/ALEX" ] ])
    expect(user.email).to end_with("@fog.invalid")
    expect(Household.count).to eq(1)

    # Usable straight away: the household's first profile is there to watch as.
    get "/api/v1/profiles", headers: { "Authorization" => "Bearer #{body['token']}" }
    expect(response).to have_http_status(:ok)
    expect(json).to be_present
  end

  it "does not set Stream up for someone fog does not make its admin" do
    returns(identity(role: "member"))
    callback!
    handoff!(fragment(response.location)["handoff"])
    user = User.find(json.dig("user", "id"))
    expect(user).not_to be_admin
  end

  context "with accounts already in Stream" do
    let(:household) { create_household }
    let!(:kim) { create_user(household: household, email: "kim@example.com", password: "passwordpassword") }

    it "never links by email: an unlinked identity is asked to prove an account is theirs" do
      returns(identity(email: "kim@example.com"))
      callback!
      expect(response.location).to start_with("http://www.example.com/auth/link#")
      expect(Identity.count).to eq(0)
    end

    it "links an account once its owner signs in to it, then signs in by identity" do
      returns(identity)
      callback!
      keep_link_cookie!
      pending = fragment(response.location)["pending"]
      post "/auth/oidc/link", params: { pending: pending, login: "kim@example.com", password: "wrong-password" }
      expect(response).to have_http_status(:unauthorized)
      post "/auth/oidc/link", params: { pending: pending, login: "kim@example.com", password: "passwordpassword" }
      expect(response).to have_http_status(:ok)
      expect(json["return_to"]).to eq("/library/x")
      handoff!(json["handoff"])
      expect(json.dig("user", "id")).to eq(kim.id)

      callback!
      expect(response.location).to start_with("http://www.example.com/auth/complete#")
    end

    it "starts a fresh account in the household when the person asks" do
      returns(identity(email: "kim@example.com"))
      callback!
      keep_link_cookie!
      post "/auth/oidc/link", params: { pending: fragment(response.location)["pending"], fresh: "true" }
      handoff!(json["handoff"])
      fresh = User.find(json.dig("user", "id"))
      expect(fresh.id).not_to eq(kim.id)
      expect(fresh.household_id).to eq(household.id)
      # Kim's address is taken, and an address never identifies anyone: the
      # new account gets a stand-in rather than failing or sharing it.
      expect(fresh.email).to end_with("@fog.invalid")
      expect(User.count).to eq(2)
    end

    it "takes the role fog decided, every sign-in" do
      Identity.create!(user: kim, issuer: issuer, subject: "person:H/KIM")
      returns(identity(role: "admin"))
      callback!
      expect(kim.reload).to be_admin
      returns(identity(role: "guest"))
      callback!
      expect(kim.reload).to be_guest
    end

    it "refuses the link step in a browser fog did not send back" do
      returns(identity)
      callback!
      expect(response.cookies[FogClient::Signin::Rails::LINK_COOKIE]).to be_present
      pending = fragment(response.location)["pending"]
      post "/auth/oidc/link", params: { pending: pending, login: "kim@example.com", password: "passwordpassword" }
      expect(response).to have_http_status(:unprocessable_content)
      cookies[FogClient::Signin::Rails::LINK_COOKIE] = "another-browser"
      post "/auth/oidc/link", params: { pending: pending, fresh: "true" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(Identity.count).to eq(0)
      expect(User.count).to eq(1)
    end

    it "refuses a pending link that was tampered with" do
      post "/auth/oidc/link", params: { pending: "not-sealed", fresh: "true" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(User.count).to eq(1)
    end
  end

  describe "visitors from a paired household" do
    let(:home) { "01JHOMEINSTANCE0000000000Z" }
    let(:household) { create_household }
    let!(:kim) { create_user(household: household, email: "kim@example.com", password: "passwordpassword") }

    # What fog's ID token says of a visitor (§10.4): their own instance in
    # subject and fog_home, the role the manifest allows, and never an email.
    def visitor(handle: "kim", role: "guest", sid: "visit-1")
      FogClient::Signin::Identity.new(issuer: issuer, subject: "person:#{home}/01JPERSON00000000000000000", handle: handle,
                                      name: "Kim Elsewhere", roles: [ role ], sid: sid, home: home, visitor: true,
                                      amr: [ "pop", "user" ])
    end

    it "gives a visitor a guest's account of their own, and signs them in" do
      body = signed_in_via_fog!(visitor)
      user = User.find(body.dig("user", "id"))
      expect(user).not_to eq(kim)
      expect(user).to be_guest
      expect(user).to be_visitor
      expect(user.visitor_home).to eq(home)
      expect(user.name).to eq("Kim Elsewhere")
      expect(user.household_id).to eq(household.id)
      expect(user.email).to end_with("@fog.invalid").and start_with("kim.")
      expect(user.identities.pluck(:issuer, :subject)).to eq([ [ issuer, visitor.subject ] ])
      expect(body.dig("user", "visitor")).to be(true)

      headers = { "Authorization" => "Bearer #{body['token']}" }
      get "/api/v1/users", headers: headers
      expect(response).to have_http_status(:ok)
      # A guest's limits, and no credential that would outlive the visit.
      post "/api/v1/notifications/read_all", headers: headers
      expect(response).to have_http_status(:forbidden)
      post "/api/v1/api_tokens", params: { name: "keep" }, headers: headers
      expect(response).to have_http_status(:forbidden)
      post "/api/v1/webauthn_credentials/register/begin", headers: headers
      expect(response).to have_http_status(:forbidden)
      expect(user.api_tokens).to be_empty
    end

    it "keeps a visitor's session to fog's visitor session, and pairs no TV" do
      body = signed_in_via_fog!(visitor)
      session = ApiSession.find_by(token: body["token"])
      expect(session.expires_at).to be_within(1.minute).of(ApiSession::VISITOR_TTL.from_now)

      pairing = DevicePairing.start!("Living Room")
      post "/api/v1/pairings/approve", params: { code: pairing.display_code }, headers: { "Authorization" => "Bearer #{body['token']}" }
      expect(response).to have_http_status(:forbidden)
    end

    it "never signs a visitor in as a household account, nor anyone in as a visitor's" do
      Identity.create!(user: kim, issuer: issuer, subject: visitor.subject)
      returns(visitor)
      callback!
      expect(response).to redirect_to("http://www.example.com/login#signin_error=visitor_mismatch")

      Identity.delete_all
      guest = User.find(signed_in_via_fog!(visitor).dig("user", "id"))
      returns(identity(subject: visitor.subject, role: "member"))
      callback!
      expect(response).to redirect_to("http://www.example.com/login#signin_error=visitor_mismatch")
      expect(guest.reload).to be_guest
    end

    it "signs the same visitor in to the same account next time" do
      first = signed_in_via_fog!(visitor)
      again = signed_in_via_fog!(visitor(sid: "visit-2"))
      expect(again.dig("user", "id")).to eq(first.dig("user", "id"))
      expect(User.where.not(visitor_home: nil).count).to eq(1)
    end

    it "never takes a visitor down the link or setup path" do
      returns(visitor)
      callback!
      expect(response.location).to start_with("http://www.example.com/auth/complete#")
      expect(response.cookies[FogClient::Signin::Rails::LINK_COOKIE]).to be_nil

      # On a Stream with no household of its own yet, a visitor is not its
      # first admin: they are refused, and do not count as anyone.
      Identity.delete_all
      User.delete_all
      Household.delete_all
      returns(visitor(role: "admin"))
      callback!
      expect(response).to redirect_to("http://www.example.com/login#signin_error=not_set_up")
      expect(User.count).to eq(0)
    end

    it "does not count visitors as the household: the first member through fog still sets Stream up" do
      kim.destroy!
      signed_in_via_fog!(visitor)
      expect(SigninAdapter.new.account_count).to eq(0)
      body = signed_in_via_fog!(identity(role: "admin", handle: "alex", subject: "person:H/ALEX"))
      expect(User.find(body.dig("user", "id"))).to be_admin
    end

    it "never makes a visitor an admin, whatever the token says" do
      body = signed_in_via_fog!(visitor)
      returns(visitor(role: "admin"))
      callback!
      user = User.find(body.dig("user", "id"))
      expect(user.reload).to be_guest
      user.role = "admin"
      expect(user).not_to be_valid
    end

    it "ends a visitor's session by its sid" do
      body = signed_in_via_fog!(visitor(sid: "visit-9"))
      allow_any_instance_of(FogClient::Signin::Backchannel).to receive(:verify)
        .and_return(FogClient::Signin::Backchannel::Logout.new(subject: nil, sid: "visit-9", jti: "j"))
      post "/auth/oidc/backchannel", params: { logout_token: "t" }
      expect(response).to have_http_status(:ok)
      expect(ApiSession.find_by(token: body["token"])).to be_nil
    end
  end

  describe "handoff" do
    it "is good once" do
      returns(identity(role: "admin"))
      callback!
      code = fragment(response.location)["handoff"]
      handoff!(code)
      expect(response).to have_http_status(:created)
      handoff!(code)
      expect(response).to have_http_status(:unauthorized)
    end

    it "is good for a minute" do
      returns(identity(role: "admin"))
      callback!
      code = fragment(response.location)["handoff"]
      travel 2.minutes do
        handoff!(code)
        expect(response).to have_http_status(:unauthorized)
      end
    end

    it "gives a fog session a lifetime and the provider's sid" do
      body = signed_in_via_fog!(identity(role: "admin", sid: "sid-9"))
      session = ApiSession.find_by(token: body["token"])
      expect(session.oidc_sid).to eq("sid-9")
      expect(session.expires_at).to be_within(1.minute).of(ApiSession::FOG_TTL.from_now)
    end
  end

  describe "back-channel logout" do
    let(:household) { create_household }
    let(:kim) { create_user(household: household) }

    def logout!(subject: nil, sid: nil)
      allow_any_instance_of(FogClient::Signin::Backchannel).to receive(:verify)
        .and_return(FogClient::Signin::Backchannel::Logout.new(subject: subject, sid: sid, jti: "j"))
      post "/auth/oidc/backchannel", params: { logout_token: "t" }
    end

    it "ends exactly the sessions the provider names" do
      Identity.create!(user: kim, issuer: issuer, subject: "person:H/KIM")
      fog = ApiSession.generate!(user: kim, oidc_sid: "sid-1", expires_at: 30.days.from_now)
      other = ApiSession.generate!(user: kim, oidc_sid: "sid-2", expires_at: 30.days.from_now)
      logout!(sid: "sid-1")
      expect(response).to have_http_status(:ok)
      expect(ApiSession.exists?(fog.id)).to be(false)
      expect(ApiSession.exists?(other.id)).to be(true)
    end

    it "ends every session of a person fog removed, and only theirs at this provider" do
      Identity.create!(user: kim, issuer: issuer, subject: "person:H/KIM")
      elsewhere = create_user(household: household)
      Identity.create!(user: elsewhere, issuer: "https://other.example", subject: "person:H/KIM")
      kims = [ ApiSession.generate!(user: kim, oidc_sid: "sid-1"), ApiSession.generate!(user: kim, device: "TV") ]
      theirs = ApiSession.generate!(user: elsewhere)
      logout!(subject: "person:H/KIM")
      expect(response).to have_http_status(:ok)
      expect(ApiSession.where(id: kims.map(&:id))).to be_empty
      expect(ApiSession.exists?(theirs.id)).to be(true)
    end

    it "refuses a token that does not verify" do
      allow_any_instance_of(FogClient::Signin::Backchannel).to receive(:verify).and_raise(FogClient::Signin::Invalid, "bad")
      post "/auth/oidc/backchannel", params: { logout_token: "t" }
      expect(response).to have_http_status(:bad_request)
    end
  end

  it "lets an expired fog session go" do
    user = create_user(household: create_household)
    session = ApiSession.generate!(user: user, oidc_sid: "s", expires_at: 1.minute.ago)
    get "/api/v1/me", headers: { "Authorization" => "Bearer #{session.token}" }
    expect(response).to have_http_status(:unauthorized)
    expect(ApiSession.exists?(session.id)).to be(false)
  end

  describe "fog only" do
    let(:on_fog) { oidc_env.merge("FOG_API_URL" => "http://fog.test", "FOG_API_TOKEN" => "apptok") }
    let!(:user) { create_user(household: create_household, email: "alex@example.com") }

    it "turns local sign-in off once Stream has proven it runs on fog" do
      stub_const("ENV", on_fog)
      allow(FogClient::Signin::Proof).to receive(:check).and_return(false)
      get "/api/v1/setup"
      expect(json["signin"]).to eq("enabled" => true, "fog_only" => false)
      post "/api/v1/session", params: { email: "alex@example.com", password: "passwordpassword" }
      expect(response).to have_http_status(:created)

      allow(FogClient::Signin::Proof).to receive(:check).and_return(true)
      get "/api/v1/setup"
      expect(json["signin"]).to eq("enabled" => true, "fog_only" => true)
      post "/api/v1/session", params: { email: "alex@example.com", password: "passwordpassword" }
      expect(response).to have_http_status(:forbidden)
    end

    context "once proven" do
      before do
        AppSetting.current.update!(fog_attested_at: 1.day.ago)
        stub_const("ENV", on_fog)
      end

      it "refuses every other door: passkeys, invites" do
        post "/api/v1/auth/passkey/login/begin"
        expect(response).to have_http_status(:forbidden)
        post "/api/v1/auth/passkey/login/finish", params: { credential: {}, challenge_token: "x" }
        expect(response).to have_http_status(:forbidden)

        invite = InviteCode.generate!(household: user.household, created_by: user, role: User::Role::Member)
        post "/api/v1/invites/accept", params: { code: invite.code, name: "N", email: "n@example.com", password: "passwordpassword" }
        expect(response).to have_http_status(:forbidden)
        expect(User.count).to eq(1)
      end

      it "turns the setup wizard off: the first person through fog is the admin" do
        user.destroy!
        get "/api/v1/setup"
        expect(json["setup_required"]).to be(false)
        post "/api/v1/setup", params: { household_name: "H", email: "a@example.com", name: "A", password: "passwordpassword" }
        expect(response).to have_http_status(:forbidden)
        post "/api/v1/setup/restore"
        expect(response).to have_http_status(:forbidden)
        expect(User.count).to eq(0)
      end

      it "stays fog-only when fog cannot be reached, and ends when Stream leaves fog" do
        allow(FogClient::Signin::Proof).to receive(:check).and_return(false)
        get "/api/v1/setup"
        expect(json.dig("signin", "fog_only")).to be(true)

        stub_const("ENV", oidc_env.except("FOG_API_URL"))
        get "/api/v1/setup"
        expect(json.dig("signin", "fog_only")).to be(false)
      end
    end
  end

  it "mints a recovery link from the console that signs the admin in once" do
    admin = create_user(household: create_household, role: "admin")
    Rails.application.load_tasks unless Rake::Task.task_defined?("stream:recovery_link")
    task = Rake::Task["stream:recovery_link"]
    task.reenable
    out = capture_stdout { task.invoke }
    code = fragment(out.strip)["handoff"]
    handoff!(code)
    expect(json.dig("user", "id")).to eq(admin.id)
    handoff!(code)
    expect(response).to have_http_status(:unauthorized)
  end

  def capture_stdout
    old = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old
  end
end
