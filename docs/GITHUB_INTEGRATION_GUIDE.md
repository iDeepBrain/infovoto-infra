# 🚀 GitHub → Cloud Build → Cloud Run CI/CD Setup

This guide connects your GitHub repos to GCP for automatic deployment.

## Current Status

✅ Repos configured with correct git user (`CristianLazoQuispe`)
✅ Tests passing locally (Vitest + pytest)
✅ Production fixes deployed (token expiry, error handling, timeouts)
✅ Services deploying to Cloud Run...

**Next:** Set up Cloud Build triggers so every `git push origin main` auto-deploys.

---

## How It Works

```
Your Code                 GitHub              GCP Cloud Build          Cloud Run
     ↓                      ↓                       ↓                      ↓
[git commit] → [git push] → [webhook] → [auto-build] → [auto-deploy] → [live]
   (local)       (main)      (trigger)      (5 min)       (2 min)       (~7 min total)
```

Every push to `main` triggers a Cloud Build that rebuilds your service and deploys it.

---

## Step 1: Connect GitHub Repositories to GCP

**In your browser, go to:**

```
https://console.cloud.google.com/cloud-build/repositories
```

### Steps:

1. Make sure you're in project **`proyectosia-423918`** (top-left dropdown)

2. Click **"2nd Gen"** tab (right side)

3. Click **"Connect Repository"** (blue button)

4. Select **"GitHub"** (not "GitHub App")

5. Click **"Authenticate with GitHub"**
   - Will open GitHub OAuth popup
   - **Important:** Login with **`cristian2023ml@gmail.com`** (your personal account, NOT marvik)
   - Click "Authorize" to let GCP access your repos

6. Select **Organization: `iDeepBrain`**

7. Check these repositories:
   ```
   ☑ infovoto-web
   ☑ infovoto-gateway
   ☑ infovoto-mcp
   ☐ infovoto-infra (optional)
   ```

8. Click **"Connect"** (bottom right)

**This creates a "mirror" of your repos in GCP. Takes ~30 seconds.**

---

## Step 2: Create Cloud Build Triggers

**Go to:**

```
https://console.cloud.google.com/cloud-build/triggers
```

### Create Trigger #1: infovoto-web

1. Click **"Create Trigger"** (blue button)

2. Fill in the form:

   | Field | Value |
   |-------|-------|
   | **Name** | `infovoto-web-deploy` |
   | **Repository** | `infovoto-web` (2nd Gen) |
   | **Branch** | `^main$` |
   | **Build configuration** | `Cloud Run` |
   | **Service name** | `web` |
   | **Region** | `us-central1` |
   | **Dockerfile** | `Dockerfile` (default) |

3. Click **"Create"**

### Create Trigger #2: infovoto-gateway

1. Click **"Create Trigger"** again

2. Fill in:

   | Field | Value |
   |-------|-------|
   | **Name** | `infovoto-gateway-deploy` |
   | **Repository** | `infovoto-gateway` (2nd Gen) |
   | **Branch** | `^main$` |
   | **Build configuration** | `Cloud Run` |
   | **Service name** | `gateway` |
   | **Region** | `us-central1` |
   | **Dockerfile** | `Dockerfile` (default) |

3. Click **"Create"**

### Create Trigger #3: infovoto-mcp

1. Click **"Create Trigger"** once more

2. Fill in:

   | Field | Value |
   |-------|-------|
   | **Name** | `infovoto-mcp-deploy` |
   | **Repository** | `infovoto-mcp` (2nd Gen) |
   | **Branch** | `^main$` |
   | **Build configuration** | `Cloud Run` |
   | **Service name** | `mcp-server` |
   | **Region** | `us-central1` |
   | **Dockerfile** | `Dockerfile` (default) |

3. Click **"Create"**

---

## That's It! ✅

You now have **automatic CI/CD**.

### Test it:

```bash
# In any repo, make a test change:
cd infovoto-web
echo "# test" >> README.md
git add README.md
git commit -m "test: trigger cloud build"
git push origin main

# Check GCP Console (builds appear in ~30 seconds):
# https://console.cloud.google.com/cloud-build/builds

# The build will:
# 1. Pull your code from GitHub (30s)
# 2. Build Docker image (3-5 min)
# 3. Push to Container Registry (1 min)
# 4. Deploy to Cloud Run (1-2 min)
# Total: ~7 minutes

# When done, your service is live with the new code!
```

---

## Manual Triggers (if needed)

If you want to redeploy without pushing code:

```bash
# Go to Cloud Build → Triggers → click trigger name → "Run"
# Or use gcloud:
gcloud builds submit --config=cloudbuild.yaml --substitutions="_SERVICE_NAME=web"
```

---

## Monitoring Deployments

**In GCP Console:**

1. **Cloud Build → Builds** — see all build logs
2. **Cloud Run → Services** — see current revisions and traffic
3. **Cloud Logging** — debug any errors

**Command line:**

```bash
# See last build logs
gcloud builds log [BUILD_ID] --limit=50

# Monitor service health
gcloud run services describe web --region=us-central1

# Tail logs
gcloud run services describe web --region=us-central1 --format=json | jq .status
```

---

## Troubleshooting

### Build fails?

1. Go to **Cloud Build → Builds** → click failed build
2. Scroll to "Build logs" section
3. Look for the error (usually Docker build or deploy permission issue)
4. Common fixes:
   - Missing Dockerfile? Check repo has one
   - Port mismatch? Make sure `--port` in Cloud Run matches app port
   - Env vars missing? Set them in Cloud Run service (not just locally)

### Deploy succeeds but service not updating?

```bash
# Force a new deployment:
gcloud run deploy web --region=us-central1 --force
```

### Rollback to previous version?

```bash
gcloud run services update web --region=us-central1 --revision=web-00002
```

---

## Security Notes

✅ Only repos in **iDeepBrain** org can trigger builds
✅ Only **GitHub (`main` branch)** can trigger (not local)
✅ Secrets stored in **GCP Secret Manager** (not in repo)
✅ Service Account has only **run.admin** and **build.editor** roles
✅ Cloud Run services are **HTTPS-only** (automatic SSL/TLS)

---

## Next Steps

1. **Create the 3 triggers** (steps above)
2. **Test one trigger** with a dummy commit to main
3. **Verify on Cloud Run** → new revision deployed
4. **Configure Cloudflare DNS** (see POST_DEPLOY_CHECKLIST.md)
5. **You're live!** Every future push auto-deploys

Questions? Check the `deploy-ordered.sh` output for service URLs.
