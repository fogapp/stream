# Accessing Stream

Every way in, what each one can do, and how it is authenticated.

## Summary

| Surface | Path | Credential | Who uses it |
|---|---|---|---|
| App | `/` | Session (fog, or email + password, or passkey) | People |
| Sign in with fog | `/auth/oidc/*` | OpenID Connect with fog (or any provider `OIDC_ISSUER` names) | People |
| API | `/api/v1/*` | Session token or API token, `Authorization: Bearer` | The app, scripts |
| API docs | `/api-docs` | None (the OpenAPI document only) | People writing clients |
| MCP | `/mcp` | API token, `Authorization: Bearer` (read-scoped tokens get read-only tools) | Assistants |
| Media | `/media/s/<token>/…` | A signed playback-session token in the path | Video elements, native HLS |
| Downloads | `/media/d/<token>/…` | A signed offline-download token in the path | Offline copies |
| Remote transcoders | `/api/v1/transcoder/*`, `/media/n/<token>/source` | A node token; a signed run token for the source | `bin/stream-transcode-worker` |
| Artwork, stills, trailers | `/artwork/…`, `/trailers/…` | A signature in the path | `<img>` and `<video>` elements |
| Sonarr/Radarr webhooks | `/hooks/arr/<token>` | The webhook's token in the path | Sonarr, Radarr |
| fog contracts | `/fog/*` | `FOG_API_TOKEN` injected by fog; `/fog/compute/runs/<token>` a signed run token | fog itself |
| Health | `/up` | None | Load balancers, fog's swap gate |
| Webhook | outbound | None | Anything that accepts a JSON POST |
| ntfy | outbound | None | An ntfy server on the fleet network |

There is **no default username or password**. A fresh instance has zero users,
and the first request to `POST /api/v1/setup` (the setup wizard) creates the
household and its admin. Whoever reaches a fresh install first owns it, so
complete the wizard right after install.

## Signing in

### Sign in with fog

On fog, Stream declares `fog-signin/1` (`fog.yaml`): fog registers it as a
client of its OpenID provider and injects `OIDC_ISSUER`, `OIDC_CLIENT_ID`
and `OIDC_CLIENT_SECRET`. The sign-in page then offers **Sign in with fog**;
fog decides who may (the app's Sign-in tab there) and as what role
(operators are admins, members are members). Outside fog the same three
variables point Stream at any OpenID provider; without them nothing
changes.

- **The first sign-in on an empty Stream is its setup**: a household and
  its admin, when fog says that person is an admin.
- **Accounts are never matched by email.** A sign-in is an (issuer,
  subject) pair. When Stream already has accounts and none is linked to
  that pair, the person signs in to theirs once with its email and
  password to connect it, or starts a fresh account in the household.
- **Sessions from fog** last at most 30 days, and end when fog says the
  fog session or the person is gone (back-channel logout to
  `/auth/oidc/backchannel`). The callback hands the browser a one-time,
  one-minute code in the URL fragment, which `POST /api/v1/handoff` trades
  for the usual token.
- **Fog only.** Once Stream proves it runs on fog — the fog that recognises
  its `FOG_API_TOKEN` signs, with the key that signs Stream's ID tokens, a
  statement naming Stream's issuer and client — it turns off passwords,
  passkeys, invite codes and the setup wizard, and fog is the only way in.
  It stays that way if fog is unreachable, and ends only when Stream is
  taken off fog (the `FOG_*` variables are gone).
- **Break-glass**: `bin/rails stream:recovery_link` on the server prints a
  single-use, ten-minute sign-in link for the first admin and records it
  in Activity. Nothing reachable from the network can mint one.

### Email and password

The sign-in page takes the email and password created in the wizard or on
an invite. Passwords are at least 10 characters. Ten failed attempts in three
minutes are rate limited.

Under the hood, `POST /api/v1/session` with `{"email": …, "password": …}`
returns `{"token": …, "user": {…}}`. The console stores the token in browser
local storage and sends it as a bearer header on every request. There are
no cookies, so there is no CSRF surface. Sign out deletes the session on the
server.

Session tokens are opaque, 64 hex characters, and **do not expire** (a
session from fog sign-in lasts at most 30 days). Revocation is signing
out, which deletes the row.

### Passkeys

Any signed-in user can enrol a passkey under **Settings › Users › Your
passkeys**: give it a nickname, press **Add a passkey**, and complete the
browser's prompt. On the sign-in page a passkey signs in without a password,
and with no email typed the browser offers every discoverable passkey.

Passkeys are additive. Password sign-in cannot be switched off (except by
fog-only sign-in, above), and removing the last passkey is allowed.

The relying-party id is `STREAM_HOST`. Changing the hostname invalidates every
passkey. Passkeys also need a secure context, so use HTTPS through the
reverse proxy.

### Roles

| Role | Can |
|---|---|
| **Admin** | Everything, including libraries, integrations, the Playback decisions page, instance settings, and invites. |
| **Member** | Watch, subscribe, curate, view everything, manage their own passkeys and API tokens. Settings are read-only. |
| **Guest** | View and watch everything (their own playback sessions and progress), and manage their own passkeys and API tokens. Any other change is refused with 403 "Guests have read-only access". |

The wizard's account is an Admin. The role of an invited user is chosen when
the invite is created.

A **visitor** — someone from a household paired with yours on fog, signed in
by their own fog (fog's signin-proposal §10.4) — gets a Guest account of
their own, listed in Settings › Users as visiting from another household.
A visitor is never an Admin, makes no passkeys or API tokens and pairs no
TV (their access lasts only as long as fog and the pairing say: a visitor's
session ends after 12 hours at most), and does not count as one of the
household when fog's first sign-in sets Stream up.

### Adding people

Only admins can invite. **Settings › Users › Invite someone**: pick a role,
press **Create invite code**, and hand over the code. Codes are 24
characters, single-use, and expire after seven days. Nothing emails them.

The invitee opens the sign-in page, enters the code with their name, email,
and password, and is signed in immediately.

## API tokens

Long-lived credentials for scripts and integrations (a yt-dlp
post-processor, a home-automation hub). **Settings › API tokens › New token**:

| Field | Notes |
|---|---|
| Name | Up to 80 characters, for your own reference. |
| Expires in (days) | 1 to 3650. Blank means never. |

The plaintext is shown **once**, in the create response. Stream stores only a
SHA-256 digest plus the first eleven characters for display. Tokens look
like:

```
stream_<48 hex characters>
```

Send it as a header:

```
Authorization: Bearer stream_…
```

A token carries exactly its owner's access. A member's token cannot do
admin things; an admin's token can. Treat it as sensitively as the password
that made it.

**Revoke** deletes the token immediately. Expired tokens stop working at the
moment of expiry and remain listed as expired.

Tokens only ever list and revoke themselves: `GET /api/v1/api_tokens` shows
the caller's own.

## The API

Everything the app does is JSON under `/api/v1`, authenticated by a
session token or an API token in the bearer header. What a native client
needs is in the OpenAPI document at `/api-docs` (`swagger/v1/openapi.yaml`,
generated from `spec/requests/openapi`); `config/routes.rb` is the full index
and every response shape lives in `app/serializers/`.

A minimal session from a shell:

```bash
# Sign in and keep the session token
TOKEN=$(curl -s -X POST https://stream.example/api/v1/session \
  -H 'Content-Type: application/json' \
  -d '{"email":"you@example.com","password":"…"}' | jq -r .token)

# Who am I
curl -s https://stream.example/api/v1/me -H "Authorization: Bearer $TOKEN"

# Mint a long-lived token for a script (plaintext is in this one response)
curl -s -X POST https://stream.example/api/v1/api_tokens \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"probe","expires_in_days":90}'

```

The main resources:

| Resource | Path |
|---|---|
| Setup and session | `setup`, `setup/restore`, `session`, `handoff`, `auth/passkey/login/*`, `invites`, `invites/accept`, `me` |
| Settings | `app_setting` |
| People and machines | `users`, `api_tokens`, `webauthn_credentials` |
| Operations | `background_jobs`, `events`, `events/trace/:trace_id`, `notifications`, `about` |

Libraries, titles, playback sessions and the rest are listed in
`config/routes.rb` and, for what a client needs, `/api-docs`.

The activity feed is at `/api/v1/events`, not `/activity`, because
ad-blocker lists kill any URL matching `*/activity`.

Errors always come back as `{"errors": ["…"]}`. Unauthenticated requests get
401; a member calling an admin action gets 403 "Admin access required".

Only the credential endpoints are rate limited (sign-in, passkey sign-in,
the fog handoff and link step, setup, invite acceptance). The API has no
CORS headers: it is same-origin from a browser and reachable from anything
else with a bearer header.

## fog contracts

These endpoints exist for fog, are authenticated by the `FOG_API_TOKEN` fog
injects, and answer 401 to everything else, including console sessions and
API tokens. If the variable is unset the whole surface is off.

| Endpoint | Contract | Does |
|---|---|---|
| `GET /fog/backup` | fog-backup/2 | Describes this app and what a backup contains. |
| `POST /fog/backup`, `GET /fog/backup/jobs/:id`, `GET …/artifact`, `DELETE …` | fog-backup/2 | Produce, poll, download, and discard a backup artifact. |
| `POST /fog/restore` | fog-backup/2 | Stage a restore on a fresh instance (refused once users exist). |

## Health

`GET /up` is unauthenticated, answers within seconds of boot, and does not
depend on the worker or the database having been migrated. Any status
below 500 means the process is up. In production it is subject to the HTTPS
redirect, so probe it through the proxy.

`GET /api/v1/about` (any signed-in user) reports the git revision, Ruby,
Rails, and Postgres versions, time zone, boot time, and free space on the
state volume. The same facts are on **Settings › About**.

## Webhooks

Sonarr and Radarr post to `/hooks/arr/<token>` (targeted scans), with the
token Settings › Integrations shows for each webhook.

Stream has **one outbound webhook**. **Settings › General › Webhook URL**
receives a JSON POST for every notification:

```json
{
  "event": "scan_finished",
  "title": "Movies: 3 new titles found",
  "path": "/settings?tab=about",
  "at": "2026-09-25T18:04:11Z",
  "app": "stream"
}
```

The POST is unsigned, carries no secret, and is not retried. A failure lands
in Activity as a warning. Private LAN addresses are allowed, for example
`http://homeassistant:8123/api/webhook/stream`.

## ntfy push

When `NTFY_URL` is set, every notification is also published to that ntfy
server on topic `NTFY_TOPIC` (default `stream`), with the title
`Stream: <event>` and the notification text as the body. No authentication is
sent; the server is assumed to be on the fleet network. A non-2xx answer is
recorded in Activity. Without `NTFY_URL`, push is silently skipped and the
in-app notification remains the record.

## Where credentials live

Every secret Stream holds on your behalf is entered in Settings, encrypted at
rest with the `AR_ENCRYPTION_*` keys, and never sent back to a browser:
the TMDB key, Sonarr/Radarr and Immich keys, OpenSubtitles credentials, and
a Plex token during migration. Losing the `AR_ENCRYPTION_*` keys loses all
of them, so keep them with the fog secrets.

Request logs filter passwords, emails, tokens, keys, and anything named
`auth`.
