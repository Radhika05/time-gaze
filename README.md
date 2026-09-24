# TimesGaze

TimesGaze is a Flutter digital photo frame app. Users sign in with Google, pick
photos from their Google Photos library, save the picks as named albums on the
device, and play them as a slideshow.

This README covers how the app gets access to Google Photos: the OAuth flow,
scopes, token handling, the configuration it needs, and the steps for Google
verification.

> **No secrets in this repository or README.** Access tokens, refresh tokens,
> OAuth client secrets and signing keys must never be committed. This document
> describes the mechanism and says *where* each value is configured. It does not
> contain the values themselves. See [Secrets and what is safe to commit](#8-secrets-and-what-is-safe-to-commit).

---

## Contents

1. [Architecture at a glance](#1-architecture-at-a-glance)
2. [Google OAuth flow](#2-google-oauth-flow)
3. [Google Photos scopes](#3-google-photos-scopes)
4. [How the user grants access (Picker flow)](#4-how-the-user-grants-access-picker-flow)
5. [Access and refresh token handling](#5-access-and-refresh-token-handling)
6. [Sign-out and revoking access](#6-sign-out-and-revoking-access)
7. [Configuration for Google API access](#7-configuration-for-google-api-access)
8. [Secrets and what is safe to commit](#8-secrets-and-what-is-safe-to-commit)
9. [Google OAuth verification](#9-google-oauth-verification)
10. [Known gaps and hardening to-do](#10-known-gaps-and-hardening-to-do)
11. [Building and running](#11-building-and-running)

---

## 1. Architecture at a glance

| Layer | Where | Role |
|---|---|---|
| Google Sign-In | `google_sign_in` plugin, configured in `lib/repositories/auth_repositories.dart` (`authRepositoryProvider`) | Runs the OAuth consent flow and issues Google access tokens |
| Firebase Auth | `firebase_auth` | Turns the Google credential into a Firebase user (`uid`) |
| Google Photos Picker API | `https://photospicker.googleapis.com/v1/...` | Lets the user choose photos in Google's own UI. The app only receives the items the user picked |
| Local storage | `flutter_secure_storage`, `shared_preferences`, app documents directory | Stores the current access token, picker session state, and downloaded album photos |
| Cloud Firestore | `usersAuthDetails/{uid}` | Per-user auth metadata (see [§10](#10-known-gaps-and-hardening-to-do)) |

The UI goes through `AuthController` (`lib/controllers/auth_controller.dart`),
which delegates to `AuthRepository`.

> **The Google Photos Library API is not used for reading.** Google removed the
> Library API's broad read scopes (`photoslibrary.readonly` and similar) for
> third-party apps on **31 March 2025**. TimesGaze uses the **Photos Picker API**
> instead. `lib/repositories/auth_silentRepo.dart` and
> `lib/screens/signInSilentlyScreen.dart` still call the old
> `photoslibrary.googleapis.com` endpoints. They are legacy, not referenced by
> the active flow, and should be deleted.

---

## 2. Google OAuth flow

TimesGaze uses the native **Google Sign-In** SDK on Android and iOS. The SDK
runs the OAuth 2.0 authorization flow with the OS account manager / Google
Identity Services, so the app never sees the user's password.

```
┌────────┐   signIn()    ┌──────────────────┐  consent screen  ┌──────┐
│  App   │ ────────────▶ │ Google Sign-In   │ ───────────────▶ │ User │
│        │ ◀──────────── │ SDK (on device)  │ ◀─────────────── │      │
└────────┘ access token  └──────────────────┘   approves       └──────┘
    │      + ID token
    │
    │ GoogleAuthProvider.credential(accessToken, idToken)
    ▼
┌───────────────┐        ┌──────────────────────────────┐
│ Firebase Auth │ ─uid─▶ │ Firestore usersAuthDetails/uid│
└───────────────┘        └──────────────────────────────┘
    │
    │ Authorization: Bearer <access token>
    ▼
┌──────────────────────────────────┐
│ photospicker.googleapis.com      │
└──────────────────────────────────┘
```

### Interactive sign-in: `AuthRepository.authenticate()`

1. `GoogleSignIn.disconnect()` clears any cached account so the account
   chooser always shows. This is how users switch accounts.
2. `GoogleSignIn.signIn()` shows the account chooser and the **consent screen**
   listing the requested scopes ([§3](#3-google-photos-scopes)).
3. `account.authentication` returns an **access token** (short-lived bearer
   token for Google APIs) and an **ID token** (a JWT that proves who the user is).
4. Both are exchanged for a Firebase session with
   `FirebaseAuth.signInWithCredential(GoogleAuthProvider.credential(...))`.
5. The access token is written to secure storage and to the user's Firestore
   document ([§5](#5-access-and-refresh-token-handling)).

### Returning users: `AuthRepository.tryAutoSignIn()`

Called from the splash screen:

1. Waits up to 5 s for Firebase Auth to restore its persisted session.
2. Calls `GoogleSignIn.signInSilently()`. The SDK reuses the existing grant
   without showing UI.
3. Gets a **fresh** access token and stores it. If any step fails the user is
   sent to the login screen.

### `serverClientId`

`GoogleSignIn` is configured with a `serverClientId`, the **Web application**
OAuth client ID from the Firebase/Google Cloud project. It is needed so the
SDK issues an ID token that Firebase Auth accepts. A client ID is a public
identifier, not a secret. The matching **client secret** must never be in the
app.

---

## 3. Google Photos scopes

Requested in `authRepositoryProvider` (`lib/repositories/auth_repositories.dart`):

| Scope | Classification | Why the app needs it |
|---|---|---|
| `email` | Non-sensitive | Identify the account (shown in profile, used for Firebase user) |
| `profile` | Non-sensitive | Display name / avatar |
| `https://www.googleapis.com/auth/photospicker.mediaitems.readonly` | **Sensitive** | Create Picker sessions and read **only the media items the user explicitly selects** in the Google Photos picker |

What the app **cannot** do with these scopes:

- List or search the user's whole library or albums
- See any photo the user did not pick
- Upload, edit, or delete anything in Google Photos

This is the narrowest scope that works for a photo frame. It also shapes the
verification requirements in [§9](#9-google-oauth-verification).

> Do not add `photoslibrary.*` read scopes back. They are no longer granted to
> third-party apps and would make verification fail.

---

## 4. How the user grants access (Picker flow)

Access has two layers: OAuth consent (once per account, [§2](#2-google-oauth-flow))
and a **per-selection** choice in the Picker. The Picker flow is in
`AuthRepository.createPickerSession()` and `fetchPickerMediaItems()`:

1. **Get a fresh token.** `getFreshAccessToken()` uses the cached account or
   `signInSilently()`, and falls back to interactive `signIn()` if that fails.
2. **Create a session.** `POST https://photospicker.googleapis.com/v1/sessions`
   returns `id` and `pickerUri`.
3. **Persist the session** in `SharedPreferences` (`picker_session_v1`). Many
   Android OEMs kill the app while the browser is in the foreground, and this
   lets the app resume afterwards.
4. **Open `pickerUri`** in the external browser / Google Photos app. The user
   picks photos in Google's UI.
5. **Poll** `GET /v1/sessions/{id}` until `mediaItemsSet == true`.
6. **List items** with `GET /v1/mediaItems?sessionId=…` (paged, 100 per page).
   Each item has a `mediaFile.baseUrl`. The app appends `=w2048-h2048`.
7. **Delete the session** with `DELETE /v1/sessions/{id}` and clear the
   persisted copy.
8. **Save as album.** `saveCurrentPhotosAsAlbum()` downloads each `baseUrl`
   **with the `Authorization: Bearer` header** (Picker base URLs require it)
   into `<app documents>/albums/<albumId>/`. Album metadata goes into
   `SharedPreferences` (`picker_albums_v2`).

Because the photos are saved on the device, the slideshow keeps working
offline and after the access token expires. Picker `baseUrl`s expire after about
60 minutes, so they are never stored long-term.

### Picker API error handling

| HTTP status | Meaning | What the app shows |
|---|---|---|
| 404 | Photos Picker API not enabled in the Cloud project | Instructions to enable it |
| 401 / 403 | Token expired, revoked, or missing the Picker scope | "Sign out and sign in again" |
| other | Transient / unknown | Generic retry message |

---

## 5. Access and refresh token handling

### Access tokens

- **Lifetime:** about 1 hour, set by Google.
- **Source:** always from the Google Sign-In SDK (`account.authentication`).
- **Refresh:** the app does **not** refresh tokens itself. When a token is
  needed, `getFreshAccessToken()` / `signInSilently()` asks the SDK, and the SDK
  returns a valid token, refreshing it internally if needed. The refresh grant
  is kept by the OS (Google Play services on Android, Keychain on iOS), **not**
  by the app.
- **Where it is stored:**
  - `flutter_secure_storage`, key `access_token`: Android Keystore-backed
    EncryptedSharedPreferences / iOS Keychain.
  - Firestore `usersAuthDetails/{uid}.access_token`, with a UTC `timestamp`.
    See [§10](#10-known-gaps-and-hardening-to-do). This should be removed.
- **Usage:** only as an `Authorization: Bearer …` header to
  `photospicker.googleapis.com` and to Picker `baseUrl` downloads.

### Refresh tokens

For the native flow the recommended design is simple: **the app never holds a
Google refresh token.** The SDK / OS handles long-lived authorization.

A legacy web-based flow is still in the code:

- `initAppLinks()` / `_handleDeepLink()` listen on the `timesgaze://callback`
  deep link (declared in `android/app/src/main/AndroidManifest.xml`) for
  `code`, `accessToken`, `refreshToken` and `idToken` query parameters.
- `_handleCodeExchange()` sends an authorization `code` to an external backend
  (`timesgaze-oauth.vercel.app`) that holds the OAuth client secret and returns
  tokens.
- A received `refreshToken` is kept in the in-memory `refreshTokenProvider` and
  written to Firestore.

If a server-side refresh flow is ever needed (for example, a headless frame
device), it must follow these rules:

1. The **client secret stays on the backend only**, in the hosting provider's
   encrypted environment variables. It never goes in the app, the repo, or the README.
2. Use **Authorization Code + PKCE**, and return tokens to the app with an
   app-link / universal-link that is verified, not a custom scheme that other
   apps can register.
3. **Never put tokens in URL query strings.** URLs end up in logs, browser
   history and referrers.
4. Store refresh tokens **server-side, encrypted**, or on the device in secure
   storage only. Never in a Firestore document that the client can read.
5. Refresh with `POST https://oauth2.googleapis.com/token`
   (`grant_type=refresh_token`) **from the backend**, and hand the app only the
   short-lived access token.
6. Handle `invalid_grant`: the user revoked access, the token expired (for
   example, 7-day expiry while the consent screen is in *Testing*), or the
   password changed. When this happens, drop the stored token and ask the user
   to sign in again.

---

## 6. Sign-out and revoking access

`AuthRepository.logOut()`:

1. Clears in-memory photos, picker session and albums.
2. Deletes downloaded album files (`<app documents>/albums/`) and the album
   index, so the next account on this device can't see them.
3. Calls `GoogleSignIn.disconnect()`, which **revokes the app's OAuth grant**
   with Google. The user will see the consent screen again next time.
4. Signs out of Firebase Auth.
5. Deletes `access_token` and `refresh_token` from secure storage.

Users can also revoke access at any time at
<https://myaccount.google.com/permissions>. The next API call then returns
401/403 and the app asks the user to sign in again.

---

## 7. Configuration for Google API access

Everything below is set in the **Google Cloud Console** / **Firebase Console**
for the project behind this app. Nothing here needs a secret in the app binary.

### 7.1 Google Cloud project

1. Use the same Cloud project as Firebase.
2. **APIs & Services → Library**: enable
   - **Photos Picker API**
   - *(Identity Toolkit is enabled automatically by Firebase Auth)*

### 7.2 OAuth consent screen (Google Auth Platform → Branding / Audience / Data access)

- App name, support email, logo
- **Authorized domains**: the domain hosting the homepage and privacy policy
- Homepage URL, **Privacy policy URL**, Terms of service URL
- **Data access / scopes**: `email`, `profile`,
  `.../auth/photospicker.mediaitems.readonly`
- **Audience**: *External*. While in *Testing*, only listed test users can
  sign in, and their grants expire after 7 days.

### 7.3 OAuth clients (Google Auth Platform → Clients)

| Client type | Used by | Required values |
|---|---|---|
| **Android** | Google Sign-In on Android | Package name `com.timesgaze.timesgaze` + **SHA-1** of *each* signing key: debug, upload, and **Play App Signing** key (from Play Console → App integrity) |
| **iOS** | Google Sign-In on iOS | Bundle ID |
| **Web application** | `serverClientId` for ID tokens / Firebase Auth | Client ID only in the app. The secret stays in the Console / backend |

> A missing or wrong SHA-1 is the most common cause of
> `PlatformException(sign_in_failed, ... 10: ...)` (DEVELOPER_ERROR) on Android.
> A release build signed by Play needs the **Play App Signing** SHA-1, not only
> the local upload key's.

### 7.4 Firebase

1. Firebase Console → Authentication → Sign-in method → enable **Google**.
2. Add the Android/iOS apps with the same package name / bundle ID and SHA-1s.
3. Regenerate the platform config with the FlutterFire CLI:
   ```bash
   dart pub global activate flutterfire_cli
   flutterfire configure
   ```
   This writes `lib/firebase_options.dart`,
   `android/app/google-services.json` and
   `ios/Runner/GoogleService-Info.plist`.

### 7.5 Platform setup

**Android:** no extra manifest entries are needed for Google Sign-In.
`google-services.json` and the SHA-1 registration are enough.

**iOS:** add the **reversed iOS client ID** as a URL scheme
(`CFBundleURLTypes` → `CFBundleURLSchemes`) in `ios/Runner/Info.plist`, and
optionally `GIDClientID`. The current `Info.plist` has neither, so Google
Sign-In on iOS will not complete until they are added.

### 7.6 Where the app reads config

| Value | Location |
|---|---|
| Scopes, `serverClientId` | `lib/repositories/auth_repositories.dart` → `authRepositoryProvider` |
| Firebase project config | `lib/firebase_options.dart`, `google-services.json`, `GoogleService-Info.plist` |
| Deep-link scheme (legacy) | `android/app/src/main/AndroidManifest.xml` (`timesgaze://callback`) |

---

## 8. Secrets and what is safe to commit

| Item | Secret? | In git? |
|---|---|---|
| OAuth **client IDs** (Android / iOS / Web) | No, public identifiers | OK |
| Firebase `apiKey`, `appId`, `projectId` (`firebase_options.dart`, `google-services.json`, `GoogleService-Info.plist`) | No, public by design. **Restrict the API key** in Cloud Console (by Android app + SHA-1 / iOS bundle, and by API) and rely on Firestore Security Rules | OK once restricted. Some teams keep them out of git anyway; if you do, regenerate them with `flutterfire configure` in CI |
| OAuth **client secret** | **Yes** | **Never.** Backend env vars only |
| **Access tokens / refresh tokens / ID tokens** | **Yes** | **Never.** Not in code, logs, screenshots, issues or README |
| Android keystore (`*.jks`, `*.keystore`), `key.properties` | **Yes** | **Never** |
| Facebook **client token** (`android/app/src/main/res/values/strings.xml`) | Semi-secret | Prefer to inject at build time |

Suggested `.gitignore` additions:

```gitignore
# Signing / secrets
*.jks
*.keystore
key.properties
.env
.env.*
```

If a secret is ever committed, **rotate it first**, then remove it from
history. Removing it from history alone is not enough.

---

## 9. Google OAuth verification

`photospicker.mediaitems.readonly` is a **sensitive** scope, so the app must pass
Google's **OAuth app verification** before it can be published to *In
production* for all users without the "unverified app" warning and the
100-user cap. Because it is sensitive and not *restricted*, **no third-party
CASA security assessment is required**.

### Checklist

1. **Branding**
   - [ ] App name matches the Play Store listing and does not imply it is made
         by Google
   - [ ] Logo (120×120) uploaded
   - [ ] Support email + developer contact email
2. **Domains**
   - [ ] Homepage and privacy policy hosted on a domain you own
   - [ ] Domain verified in **Google Search Console** by a project Owner/Editor
   - [ ] Domain added under *Authorized domains*
3. **Homepage** (public, no login needed) describes what TimesGaze does and links
   to the privacy policy
4. **Privacy policy** clearly states:
   - [ ] What Google user data is accessed (only photos the user selects in the
         Picker, plus basic profile / email)
   - [ ] How it is used (shown as a photo-frame slideshow)
   - [ ] Where it is stored (on the user's device; which auth metadata goes in
         Firebase)
   - [ ] That it is **not** shared, sold, or used for ads / AI training
   - [ ] How to delete data and revoke access (in-app sign-out, and
         <https://myaccount.google.com/permissions>)
   - [ ] Compliance with the **Google API Services User Data Policy, including
         the Limited Use requirements**
5. **Scopes**
   - [ ] Only the scopes in [§3](#3-google-photos-scopes) are requested
   - [ ] A written justification for `photospicker.mediaitems.readonly`, e.g.:
         *"TimesGaze is a digital photo frame. Users choose which Google Photos
         to display using the Google Photos Picker. The app reads only the items
         the user selects, to download and show them in an on-device slideshow."*
6. **Demo video** (unlisted YouTube link) showing:
   - [ ] The full OAuth consent screen, with the **OAuth client ID visible in
         the browser URL bar / consent screen**, in English
   - [ ] Sign-in → opening the Picker → selecting photos → the photos shown in
         the app (the scope actually being used)
   - [ ] Sign-out / revoke
7. **Submit** in Google Auth Platform → *Verification Center* and answer any
   follow-up emails from the Trust & Safety team. Expect about 3–5 business days,
   longer if they ask for changes.
8. **Keep it up to date.** Any new scope, changed branding, or new domain means
   verifying again.

---

## 10. Known gaps and hardening to-do

These are in the code today and should be fixed before (or during)
verification, because they conflict with the handling described above:

- [ ] **Tokens stored in Firestore.** `usersAuthDetails/{uid}` gets
      `access_token` (and, in the legacy deep-link path, `refreshToken`). The
      app itself reads the token back from there (`_getAccessToken()` in
      `google_photos_screen.dart`). Read it from secure storage / the SDK
      instead, and stop writing tokens to Firestore.
- [ ] **Firestore Security Rules** must at least restrict
      `usersAuthDetails/{uid}` to `request.auth.uid == uid`. The rules are not
      in this repo; add a `firestore.rules` file and deploy it.
- [ ] **Tokens printed to logs.** `print('access token silently …')` in
      `auth_silentRepo.dart`, and `print('Received access token: …')` /
      `print('Access Token: …')` / `print('Refresh Token: …')` in
      `auth_repositories.dart`. Remove them. Never log token values.
- [ ] **Legacy deep-link token flow** (`timesgaze://callback` with tokens in
      the query string, and `_handleCodeExchange` against the Vercel backend).
      Remove it if it is unused, or redesign it as described in
      [§5](#refresh-tokens).
- [ ] **Legacy Library API code** (`auth_silentRepo.dart`,
      `signInSilentlyScreen.dart`) uses endpoints that no longer work for this
      scope. Delete it.
- [ ] **iOS URL scheme** for Google Sign-In is missing
      ([§7.5](#75-platform-setup)).
- [ ] **Restrict the Firebase / Google API key** in Cloud Console.

---

## 11. Building and running

```bash
flutter pub get
flutter run            # debug; the debug SHA-1 must be registered (§7.3)
flutter build appbundle --release
```

Get SHA-1 fingerprints for §7.3:

```bash
# debug key
keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android
# or all variants via Gradle
cd android && ./gradlew signingReport
```
