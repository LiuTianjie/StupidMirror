# Licensing

StupidMirror can be used without activation indefinitely. An unactivated
installation can mirror one iPhone at a time over USB or Wi-Fi. Audio,
thumbnails, floating windows, diagnostics, settings, device removal, and
non-control MCP operations remain available.

Activation unlocks two capabilities:

- Mirroring multiple iPhones at the same time.
- Controlling iPhones from the Mac, including control MCP tools.

If a second mirror is requested before activation, the existing mirror keeps
running and the activation sheet explains the device limit. The WDA agent may
still be prepared on an unactivated installation because wireless video uses
its H.264 stream (with MJPEG fallback), but taps, swipes, typing, buttons, app
actions, screenshots, and UI-tree access remain blocked until activation.

## Architecture

- The app stores a random installation ID and an activation receipt in macOS
  Keychain. Older records can contain legacy trial timestamps; current builds
  ignore them and never restrict one-device mirroring by time.
- The installation ID is scoped to the current Mac user; no Mac serial number,
  hardware UUID, or iPhone identifier is used for licensing. Removing only the
  app bundle normally leaves the Keychain record intact, so an official
  reinstall remains activated and the original code can restore the same
  installation idempotently.
- The app calls the `stupidmirror-license` Supabase Edge Function with the
  non-secret publishable key embedded in the signed app.
- Activation tables live in the private `stupidmirror_licensing` schema. The
  app cannot read the schema or call its RPC functions directly.
- Activation and validation are rate-limited by a server-secret HMAC of the
  request network address plus a project-wide safety bucket. The private schema
  never stores a plaintext IP address, and expired buckets are removed in small
  bounded batches after two days.
- Activation codes are generated with 120 bits of CSPRNG entropy. Supabase
  stores only SHA-256 hashes of normalized codes, never the plaintext codes.
- One code activates one StupidMirror installation. Repeating activation on the
  same installation is idempotent.

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

A normal uninstall/reinstall on the same Mac user keeps the Keychain record and
does not consume another activation. If the customer erased that Keychain
record, reinstalled macOS, changed macOS users, or moved to another Mac, the
server treats it as a new installation. Either issue a new code or reset the
customer's original code with the local-only administrator tool:

```sh
~/.local/bin/stupidmirror-codes reset SM-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX
```

Reset requires confirmation, preserves the old activation as revoked history,
and makes the original code available for one new installation. Only the
locally computed code hash is sent to Supabase. The old installation will lose
its activated capabilities when it next validates online. It keeps one mirror
running, closes any additional mirror windows, and disables control.

Do not commit the generator, its Keychain token, pending journals, or generated
text files to this repository.
