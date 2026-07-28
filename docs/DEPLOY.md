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
