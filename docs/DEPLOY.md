# Deploying DepControl

The API runs as a container on **Fly.io**, the Flutter Web bundle is static and
goes to **Cloudflare Pages**, and Postgres stays where it already is
(**Supabase**). Both deploys are driven from GitHub Actions on push to `master`.

A container host rather than Kubernetes on purpose: this is one stateless binary
that is idle most of the time. A cluster would mean paying for a control plane
and always-on nodes, plus Deployment/Service/Ingress manifests and TLS wiring,
to run the same image that `fly deploy` runs from one config file.

## Order of operations

Steps 1–5 are one-time and want a shell with `flyctl` on it. The frontend
depends on the backend's URL, which does not exist until the API has deployed
once — so the backend goes first.

---

## 1. Create the Fly app

Install [flyctl](https://fly.io/docs/flyctl/install/), then:

```bash
flyctl auth login
```

```bash
flyctl apps create depcontrol-api
```

Do **not** run `fly launch` — it rewrites [fly.toml](../fly.toml), and the file
in this repo is deliberate: the build context is the repo root (the backend is a
pub workspace member and cannot resolve without `packages/shared`), and the app
is set to scale to zero.

The region is `nrt` (Tokyo) to sit next to Supabase — the `.env.example`
connection string points at `ap-northeast-1`, which keeps the database
round-trip short. Change `primary_region` if yours is elsewhere.

## 2. Give the API its secrets

These must **never** be repo secrets or baked into the image. The root
[.dockerignore](../.dockerignore) excludes `**/.env` for exactly this reason:
`dart_frog build` copies `backend/.env` into its output, which would otherwise
put your live Postgres password into an image layer.

```bash
flyctl secrets set --app depcontrol-api \
  DATABASE_URL='postgresql://postgres.ogsnkqlamfvftdgvvtje:YOUR-PASSWORD@aws-0-ap-northeast-1.pooler.supabase.com:5432/postgres?sslmode=require' \
  SUPABASE_URL='https://ogsnkqlamfvftdgvvtje.supabase.co'
```

Use the **Session pooler** string (port 5432), not transaction pooling on 6543 —
the backend uses the extended query protocol, as `.env.example` notes.

Fly injects these as environment variables at boot, which is what the backend
already expects. Setting them before the first deploy avoids a boot with no
database. Single quotes matter: the password will contain characters your shell
would otherwise expand.

## 3. Deploy the API

```bash
flyctl deploy --remote-only
```

From the repo root. `--remote-only` builds on Fly's builder, so this works
without a local Docker daemon. The URL it prints —
`https://depcontrol-api.fly.dev` — is what the frontend needs next.

After this, the same deploy happens from CI on every push to `master`.

## 4. Create the Cloudflare Pages project

A **direct-upload** project, not a Git integration: Cloudflare's build images
have no Flutter SDK, so CI builds the bundle and uploads the result.

```bash
npx --yes wrangler@3 pages project create depcontrol --production-branch=master
```

The production branch must match `--branch` in
[deploy-frontend.yml](../.github/workflows/deploy-frontend.yml), or every deploy
publishes as a preview on its own URL and the live site never changes.

Then, in the Cloudflare dashboard:

- **Account ID** — on the right of the account's Workers & Pages overview.
- **API token** — My Profile → API Tokens → Create Token → Custom, with the
  **Account · Cloudflare Pages · Edit** permission. Scope it to this account
  only. This is a long-lived credential; Cloudflare has no OIDC equivalent.

The SPA rewrite and cache headers that used to live in `firebase.json` are now
[frontend/web/_redirects](../frontend/web/_redirects) and
[frontend/web/_headers](../frontend/web/_headers), which `flutter build web`
copies into the bundle. They are versioned with the app rather than configured
at the host.

## 5. Configure the GitHub repository

In **Settings → Secrets and variables → Actions**:

| Kind     | Name                      | Value                                                |
| -------- | ------------------------- | ---------------------------------------------------- |
| Secret   | `FLY_API_TOKEN`         | `flyctl tokens create deploy --app depcontrol-api` |
| Secret   | `CLOUDFLARE_API_TOKEN`  | the Pages token from step 4                          |
| Secret   | `CLOUDFLARE_ACCOUNT_ID` | the account ID from step 4                           |
| Variable | `API_BASE_URL`          | `https://depcontrol-api.fly.dev`                   |

`flyctl tokens create deploy` is scoped to deploying this one app, which is why
it is used instead of `flyctl auth token` — that one is your whole account.

Push to `master` (or run the workflows via `workflow_dispatch`).

## 6. Point Supabase Auth at the deployed origin

Supabase rejects redirects to unknown origins, so sign-in fails on the deployed
site until this is set. In the Supabase dashboard, **Authentication → URL
Configuration**, add the Pages URL (`https://depcontrol.pages.dev`) as Site URL
and to Redirect URLs.

Pages also gives every preview deploy its own subdomain, and those are *not*
covered by the Site URL. Sign-in on a preview build fails unless you add a
wildcard (`https://*.depcontrol.pages.dev`) to Redirect URLs.

## 7. Choose how long a session lasts

Supabase issues the access token; nothing in this repo sets its lifetime. In the
dashboard, **Authentication → Sessions → Access token (JWT) expiry**, set the
value in seconds. The default is `3600` (one hour); `604800` (one week) is the
maximum Supabase accepts.

What it changes is narrower than it sounds. While the app is open,
`supabase_flutter` renews the token in the background, so a longer expiry does
not mean fewer interruptions during use — it means a browser that has been
*closed* stays signed in for a week instead of an hour. To confirm what a build
is actually running against, open **Settings** in the app: it prints the current
token's real expiry rather than repeating what this document claims.

**The cost of raising it.** The backend verifies tokens locally against the JWKS
([jwt_verifier.dart](../backend/lib/src/auth/jwt_verifier.dart)) and never calls
Supabase to ask whether a session is still wanted. Signing out clears the copy in
that browser, but a token already issued keeps being accepted until its `exp`
passes — so this setting is also the window in which a stolen or copied token
stays usable. At one hour that is a nuisance; at one week it is a decision.
Two ways to narrow it if that matters:

- Keep the expiry shorter (a day is still 24× the default) — the refresh token
  keeps people signed in either way.
- Have `requireAuth` check the token's session against Supabase's
  `/auth/v1/user` on a cache, trading a round trip for real revocation.

The in-app **device PIN** ([pin_store.dart](../frontend/lib/security/pin_store.dart))
covers the other half of the same risk — a signed-in browser left open — but only
the screen. It does not protect the token, which is in the same `localStorage`
the PIN's hash is in.

## 8. Building the two clients

One codebase, two targets. Nothing is forked: the differences are a build-time
define and three conditional points in the code, listed at the end of this
section.

**Both builds need `API_BASE_URL`.** It defaults to `http://localhost:8080`,
which on a phone means the phone.

```bash
flutter build web --release --dart-define=API_BASE_URL=https://depcontrol-api.fly.dev
```

```bash
flutter build apk --release --dart-define=API_BASE_URL=https://depcontrol-api.fly.dev
```

Run both from `frontend/`. The APK lands in
`frontend/build/app/outputs/flutter-apk/app-release.apk`.

### What the APK needs that the web build does not

**The Android SDK.** `flutter doctor` will say if it is missing; the scaffolding
in `frontend/android/` is complete either way, but nothing can be compiled
without it.

**The OAuth redirect registered in two places.** GitHub sign-in sends the
browser to `io.supabase.depcontrol://login-callback/`
([sign_in_screen.dart](../frontend/lib/auth/sign_in_screen.dart)). That URL is
claimed by an intent-filter in
[AndroidManifest.xml](../frontend/android/app/src/main/AndroidManifest.xml), and
it must *also* be added to Supabase's **Authentication → URL Configuration →
Redirect URLs**, next to the Pages origin from step 6. Miss the
Supabase half and sign-in leaves for the browser and never comes back, with no
error on either side — nothing failed, the app simply never hears anything.

**A signing key, before publishing.** The release build is still signed with the
debug keystore, so the APK installs and runs but Play will refuse it. Generating
the real one is a decision with no undo — an app's signing key cannot be changed
after the first upload — so it is deliberately not scripted here:

```bash
keytool -genkey -v -keystore depcontrol-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias depcontrol
```

Keep it out of the repo, put its passwords in `frontend/android/key.properties`
(already gitignored, along with `*.jks`), and point `signingConfigs.release` at
it in [build.gradle.kts](../frontend/android/app/build.gradle.kts).

**An application ID you are happy with.** Currently `app.depcontrol`. It is
permanent once uploaded.

### Where the two builds actually differ

- **Key derivation for the device PIN.** The browser has native PBKDF2 and
  Android does not, so `pbkdf2.dart` picks an implementation by platform. This
  is not a detail: measured in Chromium, the Dart loop costs **4.2 seconds** for
  200,000 rounds against WebCrypto's **74ms**. The web build uses WebCrypto at
  200,000 rounds; Android and any browser without a secure context use the Dart
  loop at 20,000 — a count picked so that path stays near a tenth of a second
  rather than needing to be moved off the calling thread.
- **What the PIN is worth.** [pin_scope.dart](../frontend/lib/security/pin_scope.dart)
  chooses the wording. In a browser the session token shares `localStorage` with
  the PIN hash and the lock can be stepped around from the developer console; in
  the app that storage is private and the lock means more. Shipping one
  paragraph to both would be false on one of them.
- **The OAuth redirect**, as above — `kIsWeb` picks between returning to the
  page's own origin and the deep link.

---

## Before this is production

Two things are deliberately left as-is because they are not deploy blockers, but
both should be tightened:

- **CORS is `Access-Control-Allow-Origin: *`**
  ([_middleware.dart:36](../backend/routes/_middleware.dart#L36)). Once the Pages
  URL is known, pin it to that origin.
- **Rate limit counters are per process.** `.env.example` already notes this, and
  it is now a sharper edge than it was: `fly scale count` decides how many
  machines run, and the effective limit multiplies by that number. At the
  default of one machine they match. `min_machines_running = 0` means cold
  starts, but a compiled Dart binary starts in well under a second — the wait is
  Fly booting the machine, not the app.

## Local Docker build

The build context is the **repo root**, not `backend/` — the backend is a pub
workspace member and cannot resolve without `packages/shared`:

```bash
docker build -f backend/Dockerfile -t depcontrol-api .
```
