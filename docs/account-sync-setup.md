# Account Sync — setup guide

Optional Google/Apple login that makes several devices share **one time balance**
and **one saved-recording history**. Nothing here is required for the app to run:
with no credentials configured, the account sheet simply shows no sign-in
buttons and every device stays standalone, exactly as before.

---

## How it works

### Identity

Every device already has a hardware-derived **device row** in `users`. Signing in
creates (or finds) a separate **account row** — also a `users` row, with a
`acct_…` id and no hardware. That choice is deliberate: usage metering, the WS
proxy's billing, purchases and cloud sessions all key off `users.user_id`, so a
signed-in device just addresses a different row and every one of those paths
works unchanged.

`UserService.userId` resolves to the account when signed in and the device
otherwise. `UserService.deviceUserId` stays available, because the account
endpoints authenticate as the device (the account may not exist yet at link
time).

### Combining time

`FREE_BASE_MINUTES` (30) is granted **once per account**, not once per device.
A device contributes only what it *bought*:

```
contributed_minutes = max(0, device.usage_limit_minutes - 30)
contributed_used    = min(device.used_seconds, device.usage_limit_minutes * 60)

account.usage_limit_minutes += contributed_minutes
account.used_seconds         = min(account.used_seconds + contributed_used,
                                   account.usage_limit_minutes * 60)

device.usage_limit_minutes   = 30          # its purchased time now lives in
device.used_seconds          = min(used, 1800)   # the account, not both places
```

| Devices linked | Result |
| --- | --- |
| two fresh devices, 30 min each | **30 min** — the free tier is not doubled |
| two devices with 10 h 30 m each | **20 h 30 m** — 30 free + 10 h + 10 h |
| both free tiers fully used up | limit 30 min, used 30 min — exhausted, *not* in debt, so the next purchase is honoured in full |

Used seconds are summed because spend is real and cannot be un-spent, and then
clamped to the merged limit so a merge can never silently eat a future purchase.

A device contributes **exactly once in its lifetime** (`account_members` is the
ledger). Signing out and back in, or later linking a different account,
contributes zero — that is what stops unlink/relink from minting minutes.

### Signing out

Sign-out detaches this device only: membership is marked inactive, its
account-scoped tokens are deleted, and it falls back to its own row — which now
holds just the free tier, because its purchased time lives in the account.
Signing back in restores everything. The account keeps its balance and history
throughout, and other devices are unaffected.

### What syncs

Transcript, translation, previews, **word timestamps** and **title**. Audio does
**not**: raw PCM16 WAV is ~172 MB per hour, against a 50 MB request cap and a
Postgres instance that is not object storage. A session opened on another device
shows its full text and simply has no audio player.

### Multiple tokens

`users.auth_token_hash` is a single column, so before this feature two devices on
one row would invalidate each other's token on every re-registration —
401-ping-ponging and dropping live WS proxy sessions. Tokens now live in
`auth_tokens` (one row per device), and `tokenMatchesUser()` accepts either that
table or the legacy column so older clients keep working.

---

## 1. Server (Render)

Add these environment variables. See `server/.env.example`.

| Variable | Required for | Notes |
| --- | --- | --- |
| `GOOGLE_CLIENT_IDS` | Google sign-in | Comma-separated list of **every** OAuth client ID the app may present: iOS, Android, Web. These are accepted `aud` values — public identifiers, not secrets. |
| `APPLE_CLIENT_IDS` | Apple sign-in | Defaults to `com.silsigan.app`. Only change if the bundle ID changes or you add an Apple Services ID. |
| `GOOGLE_WEB_CLIENT_ID` | Desktop only | A Google **Web application** OAuth client. |
| `GOOGLE_WEB_CLIENT_SECRET` | Desktop only | The matching secret — the only real secret here. |
| `PUBLIC_BASE_URL` | Desktop only | Defaults to `https://silsigan.onrender.com`. Used to build the OAuth redirect URI. |
| `FREE_BASE_MINUTES` | optional | Defaults to 30. Must match `AppConstants.freeBaseMinutes`. |

Schema migrations are additive and run on boot — no manual SQL. `GET /` reports
`version: 6` once the new build is live.

**The Hetzner WS proxy does not need redeploying.** It only forwards
`userId` + `token`; the multi-token check happens on the Render side, in
`/api/proxy-auth` and `/api/proxy-bill`.

---

## 2. Google Cloud Console

Create the OAuth clients under **APIs & Services → Credentials** in a project
with the OAuth consent screen configured (External, scopes `openid` + `email`).

1. **iOS client** — bundle ID `com.silsigan.app`.
2. **Android client** — package `com.silsigan.app`, plus the SHA-1 fingerprint of
   **every** signing key you use:
   - debug: `keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android`
   - release: the key in `android/key.properties`
   - Play App Signing: the SHA-1 shown in Play Console → Setup → App signing
     (Google re-signs your upload, so its fingerprint differs from your own —
     omitting it is the classic "works locally, fails from Play" bug)
3. **Web client** — needed as the Android `serverClientId` even if you never ship
   a web build, so the ID token audience is stable. Add
   `https://silsigan.onrender.com/auth/google/callback` as an authorised redirect
   URI if you also want desktop sign-in.

Then fill in `lib/utils/constants.dart`:

```dart
static const googleIosClientId    = '<iOS client ID>.apps.googleusercontent.com';
static const googleServerClientId = '<Web client ID>.apps.googleusercontent.com';
```

and put the **reversed** iOS client ID into `ios/Runner/Info.plist` under
`CFBundleURLTypes` (a placeholder with instructions is already there).

Finally set `GOOGLE_CLIENT_IDS` on Render to all three IDs, comma-separated.

---

## 3. Sign in with Apple

1. Apple Developer portal → Certificates, Identifiers & Profiles → the
   `com.silsigan.app` App ID → enable **Sign In with Apple** → Save.
2. Regenerate the provisioning profiles (Codemagic will do this automatically if
   it manages signing; otherwise refresh them in Xcode).

`ios/Runner/Runner.entitlements` and the `CODE_SIGN_ENTITLEMENTS` build setting
are already committed. **The iOS build will fail to sign until step 1 is done** —
the entitlement has to exist on the App ID.

The button is shown on iOS/macOS only. Android and Windows would need Apple's web
flow (a Services ID plus a server-signed ES256 client secret); Google sign-in
covers those platforms, and Apple's App Store guideline 4.8 only requires Sign in
with Apple to be offered where other third-party logins are — which it is, on
iOS.

---

## 4. Desktop (optional, secondary)

Windows and Linux have no native Google/Apple SDK, so the app opens the system
browser at `PUBLIC_BASE_URL/auth/google?ticket=…`, the server runs the OAuth
exchange, and the app polls `/api/account/poll` for the resulting token. Same
endpoints, same merge, different front door.

It activates only when `GOOGLE_WEB_CLIENT_ID` / `GOOGLE_WEB_CLIENT_SECRET` are
set; otherwise the sheet reports that browser sign-in is unavailable.

> macOS note: `macos/Runner/Release.entitlements` currently lacks
> `com.apple.security.network.client`, so a sandboxed macOS *release* build
> cannot make outbound requests at all — pre-existing, and it affects the whole
> app rather than just this feature.

---

## 5. Testing checklist

1. **No config** — buttons hidden, everything behaves as before.
2. **Sign in, one device** — sheet flips to "Account synced", usage figures
   unchanged (a free-tier device contributes 0 purchased minutes).
3. **Buy time, then sign in on a second device** — the second device's own
   purchased time is added; the popup total on both devices matches the sum, with
   the free 30 counted once.
4. **Save a recording on A** — open History on B; the transcript appears with its
   title, no audio player.
5. **Record on A while B is signed in** — B's remaining time drops too.
6. **Sign out on B** — B falls back to the free tier, A is unaffected, B's
   History keeps its local copies.
7. **Sign back in on B** — balance returns and no minutes are duplicated (check
   `account_members.contributed_minutes` is unchanged).
8. **Both devices recording at once** — neither gets kicked off the WS proxy
   (this is the multi-token path).
