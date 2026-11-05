# Membership

StupidMirror is free to use without signing in for one device at a time:
one mirror, one control session, audio, thumbnails, floating windows,
diagnostics, settings, and the MCP tools that do not need a second device.

Mirroring or controlling several devices at once, in the app or through MCP,
is included in the **iTool yearly membership**: ¥99/year, covering every iTool
product. Join or upgrade at <https://itool.tech/pro?from=stupidmirror>
(`/zh/pro` and `/en/pro` serve each language). A monthly iTool membership does
not include StupidMirror; the app offers an upgrade to yearly instead.

## Using it in the app

1. Open **Membership & Account…** and sign in with Google, GitHub, or email,
   using the same account as itool.tech.
2. If the account has no yearly membership, choose **Join on itool.tech**,
   pay there, and come back. The app checks again when it becomes active, or
   choose **Refresh**.
3. Signing out returns the Mac to the free one-device mode and clears the
   cached membership.

MCP tools that need a second device fail with `sign_in_required` (no account
signed in) or `membership_required` (signed in without a yearly membership).
Both messages tell the client to sign in or join, and that one device stays
free.

## How the check works

- The app asks `GET https://itool.tech/api/membership/entitlement?product=stupidmirror`
  with the user's Supabase access token. When that route answers 502/503 or
  cannot be reached, it falls back to the Supabase RPC
  `public.itool_entitlement` on the iTool project
  (`mkbeusztkzffnzjdwmqk.supabase.co`) with the publishable key and the same
  token. The app never embeds a service-role key.
- A 401 `login_required` refreshes the session and retries once. A second
  rejection, or a refused refresh, signs the account out on this Mac.
- An answer with `active: false` removes multi-device access at once and clears
  the cache.
- After an active answer, the Keychain stores the account id, `valid_until`,
  and the server time of the check. That cache keeps multi-device working
  offline for at most 7 days after the last successful check, never past
  `valid_until`, and never when the Mac clock reads earlier than the last
  check (5 minutes of skew allowed).
- The app checks again at launch, after wake, when the network returns, when
  the app becomes active, and every 24 hours.

The bundle keys `StupidMirrorSupabaseURL`, `StupidMirrorEntitlementURL`, and
`StupidMirrorLicensePublishableKey` configure the endpoints. `scripts/build-app.sh`
writes them; `scripts/build-and-upload-release.sh` refuses to ship other values.

## Legacy SM- activation codes (retired)

Releases up to 0.7.x sold perpetual `SM-` activation codes through 链动小铺 and
validated installation receipts with the `stupidmirror-license` Edge Function.
0.8.0 removes that path from the app: it no longer accepts codes, reads
installation receipts, or calls the Edge Function.

The server side is left deployed and unchanged so 0.7.x installations keep
working:

- `supabase/functions/stupidmirror-license` (Edge Function)
- `supabase/licensing-schema.sql`, `supabase/licensing-code-activation.sql`,
  `supabase/licensing-account-cutover.sql` (private `stupidmirror_licensing`
  schema)

Do not extend these files for new features. Old Keychain items
(`com.gaojiua.StupidMirror.license.v1`) stay on upgraded Macs so a downgrade
still works; 0.8.0 ignores them.

## Human follow-ups (iTool project)

- Keep `stupidmirror://auth-callback` in Supabase Authentication > URL
  Configuration. Sign-in uses the same Google / GitHub / email providers as
  itool.tech.
- Membership plans, prices, and payments are managed on itool.tech. When the
  purchase page moves, change `LicensePurchaseURLs` and the site buttons in
  `docs/index.html`.
