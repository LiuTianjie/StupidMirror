# Licensing

StupidMirror can be used without activation indefinitely. An unactivated
installation can mirror one iPhone at a time over USB or Wi-Fi. Audio,
thumbnails, floating windows, diagnostics, settings, device removal, and
non-control MCP operations remain available. That free one-device path does
not require signing in.

Activation unlocks simultaneous mirroring and control of multiple devices.
Without activation, one mirror and one control session remain available. If a
second session is requested, the existing session keeps running and the license
sheet offers direct code activation.

## Buy and activate

Enter an **SM-** activation code to unlock multiple devices. No sign-in is
required to open the store, enter a code, or activate this Mac.

1. Buy a StupidMirror **SM-** activation code on 链动小铺 using the replaceable
   in-app constant `LicensePurchaseURLs.buyURL`
   (<https://wzyp.cn/item/exords>).
2. Paste the code into the app and choose **Activate**. Signed-out activation
   binds the receipt to the current Mac installation.
3. Account sign-in is optional: use the existing **iTool** Google / GitHub /
   email identity to restore an account license or bind this Mac's license.
   If already signed in, activation preserves account-based redemption.

StupidMirror never redeems iTool `IT-` Pro codes. Buying iTool Pro does not
activate mirroring; redeeming SM- does not grant iTool Pro. Only `SM-` codes
redeem here.

## Architecture

- The app stores a random installation ID and an activation receipt in macOS
  Keychain. Older records can contain legacy trial timestamps; current builds
  ignore them and never restrict one-device mirroring by time.
- The installation ID is scoped to the current Mac user; no Mac serial number,
  hardware UUID, or iPhone identifier is used for licensing. After a license
  is claimed or redeemed onto an account, `installation_hash` is device
  metadata only. The account (`auth.uid()`) is the license principal.
- Google / GitHub / email sessions are stored in a separate Keychain item.
  The app never embeds a Supabase service-role key. Provider client secrets
  stay in the Supabase dashboard.
- SM licensing tables live on the **iTool** Supabase project
  (`mkbeusztkzffnzjdwmqk.supabase.co`) so JWT `auth.uid()` matches iTool Pro
  users. iTool Pro (`IT-`, `plan_expires_at`) and StupidMirror (`SM-`) remain
  separate entitlements on that same uid.
- The app calls the `stupidmirror-license` Supabase Edge Function with the
  non-secret publishable key embedded in the signed app. Redeem, claim, and
  account validation also send the user's Supabase access token.
- Activation tables live in the private `stupidmirror_licensing` schema. The
  app cannot read the schema or call its RPC functions directly. RPCs remain
  `service_role`-only.
- Activation, redeem, claim, and validation are rate-limited by a server-secret
  HMAC of the request network address plus a project-wide safety bucket. The
  private schema never stores a plaintext IP address or plaintext activation
  code, and expired buckets are removed in small bounded batches after two
  days.
- Activation codes are generated with 120 bits of CSPRNG entropy. Supabase
  stores only SHA-256 hashes of normalized codes, never the plaintext codes.
- One live seat per code. Unused `available` codes activate this Mac without login, or redeem
  onto an account when already signed in. An already-activated Mac-bound code cannot be redeemed again;
  the signed-in owner claims it from the Keychain receipt instead.

## Existing Mac-bound receipts

Valid installation receipts continue working without signing in. Account binding
is optional and one-way: possession of the receipt binds the existing activation
to `auth.uid()` on the same row without minting a second seat. After optional
binding, sign in to that account to restore its license on another Mac.

v0.3.3 no longer expires a local installation receipt at the historical claim
deadline. For existing servers, manually apply
`supabase/licensing-code-activation.sql` before the former grace period ends.
This additive migration removes the server deadline without changing code hashes,
receipts, revocation, rate limits, or account ownership checks. It supports both
historical schema layouts; do not re-run the greenfield schema on live data.
The app release does not deploy this SQL automatically.

## Human follow-ups (iTool project)

Verified: SM tables and Edge Functions target the **iTool** Supabase project
`https://mkbeusztkzffnzjdwmqk.supabase.co` (same Auth as itool.tech).

1. **Do not enable extra Auth providers** if Google / GitHub / email already
   work for iTool. Only add the redirect URL `stupidmirror://auth-callback`
   under Authentication > URL Configuration.
2. For an existing deployment, apply `supabase/licensing-code-activation.sql`
   in the SQL editor. Do not re-run a greenfield schema or the historical
   account cutover for this app update.
3. This release does not change the deployed Edge Function. Installation
   activation still uses its existing `activate` endpoint.
4. When Alex sends a new SM 链动小铺 link, change only `LicensePurchaseURLs.buyURL`
   and the matching site button in `docs/index.html`.

## Generate activation codes

The administrator tool is intentionally installed outside this repository. Its
admin token is a dedicated 256-bit value in macOS Keychain; it is not a
Supabase secret or service-role key.

```sh
~/.local/bin/stupidmirror-codes 100
```

The command registers the batch atomically, then writes a private `0600` text
file under:

```text
~/.local/state/stupidmirror-license-admin/output/
```

The file contains one activation code per line. If the network response is
lost after Supabase commits a batch, the next command resumes the same pending
batch instead of silently losing or duplicating codes.

## Reinstall, replacement Mac, or lost Keychain state

After a license is bound to an account, sign in on the new Mac. The account
seat moves with `auth.uid()`; do not issue a second Mac-bound activation for
the same code.

A normal uninstall/reinstall on the same Mac user keeps the Keychain record.
Unclaimed Mac-bound receipts still restore that installation idempotently
without signing in.

Admin reset now revokes every live seat for that code (Mac-bound and
account-bound) before making the hash available again. If the code was ever
account-bound, reset leaves it `account_only` so a v0.2.x Mac-bound activate
cannot mint a second seat. New clients redeem the reset code onto an account
after login.

```sh
~/.local/bin/stupidmirror-codes reset SM-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX
```

Reset requires confirmation. Only the locally computed code hash is sent to
Supabase. The previous installation or account loses activated capabilities
when it next validates online. It keeps one mirror running, closes any
additional mirror windows, and disables extra control.

Do not commit the generator, its Keychain token, pending journals, or generated
text files to this repository.
