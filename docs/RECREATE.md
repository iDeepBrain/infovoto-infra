# Recreate / Re-activate InfoVoto from scratch

This runbook lets you rebuild the whole system after the local working folder has been
deleted. Everything needed lives in three durable places: **the public GitHub repos**
(`github.com/iDeepBrain/infovoto-*`), **GCP Secret Manager** (all credentials), and
**GCS buckets** (binary assets). No local files are required.

- **GCP project:** `proyectosia-423918`  ·  **Region:** `us-central1`
- **GitHub org:** `iDeepBrain`  ·  **SSH host alias:** `github.com-personal`

---

## 0. Prerequisites

```bash
gcloud config set account cristian2023ml@gmail.com
gcloud config set project proyectosia-423918
gh auth status            # logged in as CristianLazoQuispe
```

## 1. Clone the repos

```bash
mkdir InfovotoProject && cd InfovotoProject
for r in gateway mcp web scraper infra planning docs agent data-analysis gradio; do
  git clone git@github.com-personal:iDeepBrain/infovoto-$r.git
done
```

## 2. Restore local secrets from Secret Manager

The deployed services read secrets from Secret Manager automatically (via `--set-secrets`
in each `cloudbuild.yaml`). For **local development** you need a `.env.secrets`. Pull every
secret back into the file (values never leave your machine):

```bash
cd InfovotoProject
: > .env.secrets
for s in $(gcloud secrets list --project=proyectosia-423918 --format='value(name)'); do
  printf '%s=%s\n' "$s" "$(gcloud secrets versions access latest --secret="$s" --project=proyectosia-423918)" >> .env.secrets
done
```

> Secrets were backed up with `infovoto-infra/scripts/gcp/backup_secrets_to_sm.sh`.
> Note: `ALMA_*` secrets belong to a different project (Alma) and can be ignored here.

## 3. Run locally

```bash
cd infovoto-infra
cp ../.env.config.example ../.env.config     # adjust local URLs/ports
make up        # gateway + web + mcp + postgres + redis (docker-compose)
make health
```

Binary assets (GeoLite2, ChromaDB index, sprites) are pulled from GCS by the build, or
mounted locally — see `Makefile` targets (`make gcs-upload-mmdb`, etc.).

## 4. Re-activate on Cloud Run (next election)

Binary assets are already in GCS:
- `gs://proyectosia-423918_cloudbuild/assets/` — `GeoLite2-City.mmdb`, `chromadb_perfiles/`, `sprites/`
- `gs://infovoto-mcp-data/` — `chroma/`, `scraper/processed/debates/`

Deploy each service from its repo (build pulls assets + reads secrets from Secret Manager):

```bash
# per service dir (infovoto-mcp, infovoto-gateway, infovoto-web):
gcloud builds submit --config cloudbuild.yaml .
# then, to keep idle cost low:
gcloud run services update <web|gateway|mcp-server> --region=us-central1 --min-instances=0
```

To restore CI/CD (auto-deploy on push), recreate the Cloud Build triggers — one per repo,
pointing at the `iDeepBrain` GitHub connection (see `infovoto-infra/docs/CLOUD_BUILD_SETUP.md`
and `GITHUB_INTEGRATION_GUIDE.md`). Alternatively keep deploying manually with the command
above (no triggers needed).

## 5. Turn the web chatbot back on

The web runs in **demo mode** by default. To reconnect it to a live gateway, set
`NEXT_PUBLIC_DEMO_MODE=false` at build time (see `infovoto-web/app/chat/page.tsx`) and
redeploy `web`.

---

## What is where (durability map)

| Asset | Location | Safe after local delete? |
|---|---|---|
| All source code + full git history | GitHub `iDeepBrain/infovoto-*` (public) | ✅ |
| All credentials | GCP Secret Manager (`proyectosia-423918`) | ✅ (after running the backup script) |
| GeoLite2, ChromaDB index, sprites, debates | GCS buckets | ✅ |
| Architecture diagrams | `infovoto-docs/assets/diagrams/` | ✅ |
| Raw editable sprite source frames (488 MB, 1865 files) | GCS `gs://proyectosia-423918_cloudbuild/assets/generated_frames/` | ✅ (to re-edit the mascot: `gsutil -m cp -r gs://proyectosia-423918_cloudbuild/assets/generated_frames .`) |
