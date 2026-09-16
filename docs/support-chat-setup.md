# Support chat — setup guide

In-app 1:1 messaging between a customer and anyone flagged `service_admin`
on the `users` table. The chat itself works with no extra config (the app
polls while the thread is open). Push notifications are optional and stay
off until Firebase is wired on both the client and Render.

Full setup: this file. The feature is off-by-default for push, not for chat.

---

## How it works

Every identity (`UserService.userId` — the shared account row when signed in,
the device otherwise) has **at most one** thread. Sending the first message
creates it; later messages append. There is no bot and no ticket queue —
it is a single continuous history, like a text thread.

Anyone with `users.service_admin = TRUE` (or a signed-in account whose
linked device is flagged) sees every thread in the inbox and can reply as
the team. Customers only ever see their own.

Push: a customer message wakes every admin device; a team reply wakes that
customer. Tokens live in `push_tokens`, keyed by the FCM token so sign-in /
sign-out just moves the row.

---

## Flag a team member

Run once against Render Postgres, using the 8-char **customer ID** from
Add More Time (that is `users.friend_code` of the *device* row):

```sql
UPDATE users SET service_admin = TRUE WHERE friend_code = 'ABCD1234';
```

If they later sign into an Apple/Google account, the app authenticates as
the `acct_…` row. The server treats that account as admin too, as long as
the flagged device is still an active member — no second UPDATE needed.

To revoke:

```sql
UPDATE users SET service_admin = FALSE WHERE friend_code = 'ABCD1234';
```

The next `/api/support/status` call drops them out of the inbox.

---

## Push notifications (optional)

Without the steps below, chat still works. There is just no banner when
the app is in the background.

### 1. Firebase project

1. Create (or reuse) a Firebase project, add iOS (`com.silsigan.app`) and
   Android (`com.silsigan.app`) apps.
2. Apple: upload an APNs key (Apple Developer → Keys → Apple Push
   Notifications service) under Firebase → Project settings → Cloud
   Messaging.
3. Android: download `google-services.json` when you add the Android app.
   `flutterfire configure` places it; do not commit a dummy file.

### 2. Client config (done)

`android/app/google-services.json`, `ios/Runner/GoogleService-Info.plist`,
and `lib/firebase_options.dart` are generated from Firebase project
`silsigan-ebbee` (Android + iOS apps, package/bundle `com.silsigan.app`).
Re-run `flutterfire configure` only if you add another platform.

`ios/Runner/Runner.entitlements` already has `aps-environment`, and
`Info.plist` already lists `remote-notification`. You still need to enable
the **Push Notifications** capability on the `com.silsigan.app` App ID in
the Apple Developer portal (same place Sign in with Apple was turned on),
or the next iOS build will fail provisioning.

For **Play closed beta**, add both SHA-1 fingerprints to the Firebase
Android app (Project settings → Your apps): the **upload key** and Play
Console → App integrity → **App signing key certificate**. Play re-signs
the AAB; without the Play SHA-1, local builds get tokens and the beta
build does not.

### 3. Render (FCM send)

Firebase console → Project settings → Service accounts → Generate new
private key. Paste the JSON as **one line** into a Render env var:

```
FIREBASE_SERVICE_ACCOUNT={"type":"service_account",...}
```

If the dashboard chokes on quoting, base64-encode the file instead:

```
FIREBASE_SERVICE_ACCOUNT_BASE64=eyJ0eXBlIjoic2VydmljZV9hY2NvdW50Ii...
```

Render auto-deploys `server/index.js` on push to master; the support
routes live in `server/support-chat.js` and run `ensureSupportSchema` on
boot (`service_admin` column, `support_threads`, `support_messages`,
`push_tokens`).

The next send after that env var is set logs
`support-chat: push enabled (project …)`. Until then it logs
`FIREBASE_SERVICE_ACCOUNT not set — push disabled`.

### 4. Permission prompt

The OS prompt is **not** shown at launch. Customers are asked after their
first sent message; team members are asked when they open the inbox. That
is the moment a notification is obviously useful.

---

## Entry points in the app

- **Add More Time** sheet → **Contact Support**. Closes the sheet first, so
  Back from the chat returns to the main screen.
- A push banner / in-app snackbar **Open** action jumps straight to the
  thread (inbox first, for team members, unless the payload names a
  customer).
- Team members tapping Contact Support land in the inbox.

---

## Related files

| Path | Role |
| --- | --- |
| `lib/ui/screens/support_chat_screen.dart` | Customer thread + team reply view |
| `lib/ui/screens/support_inbox_screen.dart` | Team inbox |
| `lib/services/support_service.dart` | HTTP client |
| `lib/services/push_service.dart` | FCM wrapper (safe no-op without config) |
| `server/support-chat.js` | Schema, REST, FCM HTTP v1 send |
