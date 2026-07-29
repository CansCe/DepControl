# Deploying DepControl

The API runs as a container on **Cloud Run**, the Flutter Web bundle is static
and goes to **Firebase Hosting**, and Postgres stays where it already is
(**Supabase**). Both deploys are driven from GitHub Actions on push to `master`.

Cloud Run rather than GKE on purpose: this is one stateless binary that is idle
most of the time. GKE would mean paying for a control plane and always-on nodes,
plus Deployment/Service/Ingress manifests and TLS wiring, to run the same image
that Cloud Run runs from a single `gcloud run deploy`.

## Order of operations

Steps 1–5 are one-time. Note that step 6 depends on the backend's URL, which
does not exist until the backend has deployed once — so the backend goes first.

---

## 1. Create the GCP project and enable services

```bash
gcloud projects create depcontrol-prod --name="DepControl"
gcloud config set project depcontrol-prod
```

Attach a billing account (required even on free tier), then:

```bash
gcloud services enable \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  iamcredentials.googleapis.com \
  firebasehosting.googleapis.com
```

## 2. Create the Artifact Registry repository

The name and region must match `REPOSITORY` and `GCP_REGION` in
[deploy-backend.yml](../.github/workflows/deploy-backend.yml).

```bash
gcloud artifacts repositories create depcontrol \
  --repository-format=docker \
  --location=asia-northeast1
```

Pick the region closest to your Supabase instance — the `.env.example`
connection string points at `ap-northeast-1`, so `asia-northeast1` keeps the
database round-trip short.

## 3. Store the secrets in Secret Manager

These must **never** be repo secrets or baked into the image. The root
[.dockerignore](../.dockerignore) excludes `**/.env` for exactly this reason:
`dart_frog build` copies `backend/.env` into its output, which would otherwise
put your live Postgres password into an image layer.

```bash
printf '%s' 'postgresql://postgres.ogsnkqlamfvftdgvvtje:YOUR-PASSWORD@aws-0-ap-northeast-1.pooler.supabase.com:5432/postgres?sslmode=require' \
  | gcloud secrets create depcontrol-database-url --data-file=-

printf '%s' 'https://ogsnkqlamfvftdgvvtje.supabase.co' \
  | gcloud secrets create depcontrol-supabase-url --data-file=-
```

Use the **Session pooler** string (port 5432), not transaction pooling on 6543 —
the backend uses the extended query protocol, as `.env.example` notes.

## 4. Create the deploy service account

```bash
PROJECT_ID=depcontrol-prod
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')

gcloud iam service-accounts create github-deployer \
  --display-name="GitHub Actions deployer"

SA="github-deployer@${PROJECT_ID}.iam.gserviceaccount.com"

for ROLE in \
  roles/run.admin \
  roles/artifactregistry.writer \
  roles/firebasehosting.admin \
  roles/iam.serviceAccountUser
do
  gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${SA}" --role="$ROLE"
done
```

Cloud Run's *runtime* service account is what actually reads the secrets at
request time, and it is a different identity from the deployer:

```bash
gcloud secrets add-iam-policy-binding depcontrol-database-url \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role=roles/secretmanager.secretAccessor

gcloud secrets add-iam-policy-binding depcontrol-supabase-url \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role=roles/secretmanager.secretAccessor
```

## 5. Wire up Workload Identity Federation

This is what lets the workflows authenticate with a short-lived OIDC token
instead of a long-lived service account JSON key pasted into a repo secret.

```bash
gcloud iam workload-identity-pools create github \
  --location=global --display-name="GitHub Actions"

gcloud iam workload-identity-pools providers create-oidc github-provider \
  --location=global \
  --workload-identity-pool=github \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository == 'CansCe/project_cloud'"
```

The `attribute-condition` is the security boundary — without it, *any* GitHub
repository could mint tokens for this service account.

```bash
gcloud iam service-accounts add-iam-policy-binding "$SA" \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/attribute.repository/CansCe/project_cloud"
```

Get the provider resource name for the next step:

```bash
gcloud iam workload-identity-pools providers describe github-provider \
  --location=global --workload-identity-pool=github --format='value(name)'
```

## 6. Configure the GitHub repository

In **Settings → Secrets and variables → Actions**:

| Kind     | Name                  | Value                                                         |
|----------|-----------------------|---------------------------------------------------------------|
| Secret   | `GCP_WIF_PROVIDER`    | the provider resource name printed above                      |
| Secret   | `GCP_SERVICE_ACCOUNT` | `github-deployer@depcontrol-prod.iam.gserviceaccount.com`     |
| Variable | `GCP_PROJECT_ID`      | `depcontrol-prod`                                             |
| Variable | `GCP_REGION`          | `asia-northeast1`                                             |
| Variable | `API_BASE_URL`        | the Cloud Run URL — **fill in after the first backend deploy** |

Push to `master` (or run *deploy-backend* via `workflow_dispatch`). The last
step prints the service URL; put it in `API_BASE_URL`, then run
*deploy-frontend*.

## 7. Point Supabase Auth at the deployed origin

Supabase rejects redirects to unknown origins, so sign-in fails on the deployed
site until this is set. In the Supabase dashboard, **Authentication → URL
Configuration**, add the Firebase Hosting URL
(`https://depcontrol-prod.web.app`) as Site URL and to Redirect URLs.

## 8. Choose how long a session lasts

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

## 9. Building the two clients

One codebase, two targets. Nothing is forked: the differences are a build-time
define and three conditional points in the code, listed at the end of this
section.

**Both builds need `API_BASE_URL`.** It defaults to `http://localhost:8080`,
which on a phone means the phone.

```bash
flutter build web --release --dart-define=API_BASE_URL=https://depcontrol-api-xxxx.run.app
```

```bash
flutter build apk --release --dart-define=API_BASE_URL=https://depcontrol-api-xxxx.run.app
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
Redirect URLs**, next to the Firebase Hosting origin from step 7. Miss the
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
  ([_middleware.dart:36](../backend/routes/_middleware.dart#L36)). Once the
  Hosting URL is known, pin it to that origin.
- **Rate limit counters are per process.** `.env.example` already notes this;
  with `--max-instances 4` the effective limit is up to 4× what you configure.
  Keeping `--min-instances 0` means cold starts, but a compiled Dart binary
  starts in well under a second.

## Local Docker build

The build context is the **repo root**, not `backend/` — the backend is a pub
workspace member and cannot resolve without `packages/shared`:

```bash
docker build -f backend/Dockerfile -t depcontrol-api .
```
