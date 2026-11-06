# typed: strict
# frozen_string_literal: true

# What fog sign-in means for Stream's own accounts
# (fog:docs/signin-proposal.md §15): FogClient::Signin::Rails asks, this
# answers in Stream's models. Stream keeps its users, its sessions and its
# roles; fog proves who someone is. Profiles are the household's, not the
# account's, so a new account needs none: the household's first profile is
# made the first time anyone watches (Profile.default_for).
class SigninAdapter
  extend T::Sig

  ADMIN_ROLE = T.let(User::Role::Admin.serialize, String)

  sig { returns(String) }
  def admin_role = ADMIN_ROLE

  sig { params(issuer: String, subject: String).returns(T.nilable(User)) }
  def find_by_identity(issuer, subject)
    Identity.find_by(issuer: issuer, subject: subject)&.user
  end

  # SCIM-provisioned accounts carry the subject before anyone signs in
  # (signin-proposal §12); until Stream takes SCIM there are none.
  sig { params(subject: String).returns(T.nilable(User)) }
  def find_by_external_id(subject) = nil

  # Visitors are not the household: one signing in first never makes a
  # fresh Stream theirs.
  sig { returns(Integer) }
  def account_count = User.household_members.count

  # The first sign-in on a fresh Stream is the setup wizard: a household and
  # its admin, named for the person fog says this is.
  sig { params(identity: FogClient::Signin::Identity).returns(User) }
  def bootstrap!(identity)
    ActiveRecord::Base.transaction do
      household = Household.create!(name: "Home")
      create_user(household, identity, ADMIN_ROLE)
    end
  end

  # Someone new joins the household an invite would have put them in: the
  # one this Stream was set up with.
  sig { params(identity: FogClient::Signin::Identity).returns(User) }
  def provision!(identity)
    household = Household.order(:created_at).first || Household.create!(name: "Home")
    create_user(household, identity, role_for(identity))
  end

  # A visitor (§10.4): someone from a paired household, signed in by their
  # own fog, who gets a guest's account of their own here. Never one of the
  # household's: the kit never links, adopts or bootstraps a visitor, and
  # their subject names their home instance, so the account and its email
  # stand-in are theirs alone. fog never grants a visitor more than the
  # manifest's visitors.role, and apply_role! still refuses admin. A Stream
  # nobody has set up yet has no household to visit.
  sig { params(identity: FogClient::Signin::Identity).returns(User) }
  def visit!(identity)
    household = Household.order(:created_at).first
    raise FogClient::Signin::Denied.new("not_set_up", "Stream is not set up yet") if household.nil?

    household.users.create!(
      email: email_for(identity), name: identity.name.presence || identity.handle.presence || "A visitor",
      password: SecureRandom.urlsafe_base64(32), role: User::Role::Guest.serialize,
      visitor_home: home_of(identity),
    )
  end

  # So a visitor never signs in as one of the household's accounts, nor
  # anyone else as a visitor's (the kit's Linker refuses the mismatch).
  sig { params(user: User).returns(T::Boolean) }
  def visitor_account?(user) = user.visitor?

  # Also how a visitor's account remembers them: the kit calls it right
  # after visit!, so the next sign-in finds the account by identity.
  sig { params(user: User, identity: FogClient::Signin::Identity).void }
  def link!(user, identity)
    Identity.create!(user: user, issuer: identity.issuer, subject: identity.subject)
    if user.visitor?
      Activity.record(source: "auth", event: "visitor.arrived", subject: user, household_id: user.household_id,
        summary: "#{user.name} is visiting from another household")
    else
      Activity.record(source: "auth", event: "identity.linked", subject: user, household_id: user.household_id,
        summary: "#{user.name}'s account now signs in with #{identity.handle.presence || 'fog'}")
    end
  end

  # The link page's proof that an existing account is theirs: the same email
  # and password sign-in takes. The email finds the account the person
  # named; it is never how a fog identity finds one.
  sig { params(login: String, password: String).returns(T.nilable(User)) }
  def authenticate_local(login, password)
    user = User.household_members.find_by(email: login.strip.downcase)
    user if user&.authenticate(password)
  end

  # fog decided the role; Stream only refuses one it does not know, and
  # admin for a visitor (fog never grants it; User refuses it too).
  sig { params(user: User, role: String).void }
  def apply_role!(user, role)
    return unless User::Role.has_serialized?(role)
    return if user.role == role
    return if user.visitor? && role == ADMIN_ROLE

    user.update!(role: role)
  end

  sig { params(user: User, identity: FogClient::Signin::Identity).returns(String) }
  def start_session!(user, identity)
    ttl = user.visitor? ? ApiSession::VISITOR_TTL : ApiSession::FOG_TTL
    session = ApiSession.generate!(user: user, device: "fog", oidc_sid: identity.sid, expires_at: ttl.from_now)
    Activity.record(source: "auth", event: "fog.signed_in", summary: "#{user.name} signed in with fog",
      subject: user, household_id: user.household_id)
    session.issue_handoff!
  end

  # Back-channel logout: a sid ends exactly the sessions it started; a
  # subject alone (the person was suspended or removed, or a visitor's
  # household unpaired) ends every session of the accounts linked to it at
  # this provider. A visitor's sessions carry their sid like anyone's.
  sig { params(sid: T.nilable(String), subject: T.nilable(String), issuer: T.nilable(String)).returns(Integer) }
  def end_sessions!(sid:, subject:, issuer: nil)
    if sid.present?
      ApiSession.where(oidc_sid: sid).destroy_all.size
    elsif subject.present?
      user_ids = Identity.where(issuer: issuer || FogClient::Signin.config&.issuer, subject: subject).select(:user_id)
      ApiSession.where(user_id: user_ids).destroy_all.size
    else
      0
    end
  end

  private

  # The fog instance a visitor comes from: fog_home, or the instance their
  # subject (person:<instance>/<person>) names.
  sig { params(identity: FogClient::Signin::Identity).returns(String) }
  def home_of(identity)
    identity.home.presence || identity.subject.delete_prefix("person:").split("/").first.to_s
  end

  sig { params(identity: FogClient::Signin::Identity).returns(String) }
  def role_for(identity)
    role = identity.role.to_s
    User::Role.has_serialized?(role) ? role : User::Role::Member.serialize
  end

  sig { params(household: Household, identity: FogClient::Signin::Identity, role: String).returns(User) }
  def create_user(household, identity, role)
    household.users.create!(
      email: email_for(identity), name: identity.name.presence || identity.handle.presence || "Someone",
      password: SecureRandom.urlsafe_base64(32), role: role,
    )
  end

  # Stream's accounts need an email; a fog person may have none (a visitor
  # never does), one fog has not verified, or one another account already
  # uses (it is display only, and never how anyone is found). The stand-in is under .invalid (RFC 2606), so
  # it can never deliver or collide with a real address, and it is built
  # from a digest of the identity so any provider's subject makes a valid one.
  sig { params(identity: FogClient::Signin::Identity).returns(String) }
  def email_for(identity)
    given = identity.email.to_s.strip.downcase
    if identity.email_verified == true && given.match?(URI::MailTo::EMAIL_REGEXP) && !User.exists?(email: given)
      return given
    end

    handle = identity.handle.to_s.downcase.gsub(/[^a-z0-9_-]/, "").first(32).presence || "person"
    # A visitor's says where they are from, at a glance, beside a local kim's.
    handle = "#{handle}.#{home_of(identity).downcase.last(6)}" if identity.visitor?
    "#{handle}.#{Digest::SHA256.hexdigest("#{identity.issuer} #{identity.subject}").first(12)}@fog.invalid"
  end
end
