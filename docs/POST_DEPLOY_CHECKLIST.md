# ✅ Post-Deploy Verification Checklist

After `deploy-ordered.sh` completes, verify production is working:

## 1️⃣ Check Services Are Live (after script finishes)

```bash
# Read the URLs from the script output and test them:

# MCP Server (should return 200 with no auth)
curl https://mcp-server-s2r4lxjhtq-uc.a.run.app/health

# Gateway (should return {"status":"healthy","environment":"production"})
curl https://gateway-<hash>.us-central1.run.app/health

# Web (should return 200 with HTML)
curl https://web-<hash>.us-central1.run.app
```

## 2️⃣ Verify Security & Config (CRITICAL)

```bash
# Gateway — check environment is set to production
GATEWAY_URL="https://gateway-<hash>.us-central1.run.app"

# Should return: {"status":"healthy","environment":"production"}
curl "$GATEWAY_URL/health" | grep production

# Should return 404 (docs hidden in production)
curl "$GATEWAY_URL/docs" | grep -i "404\|not found"

# Should return 401 (test bypass disabled)
curl -H "X-Test-User-Id: test" "$GATEWAY_URL/api/chat" | grep -i "401\|unauthorized"
```

## 3️⃣ Test End-to-End Flow (with real token)

1. Open **web URL** in browser
2. Click "Continuar con Google" → login with your Google account
3. DevTools → **Network tab** → check "Authorization: Bearer <token>" in chat request
4. Send a message → should get response from Gemini
5. Network tab → verify response came from `https://gateway-<hash>/api/chat`

## 4️⃣ Cloudflare DNS Setup

Once all services show as "✅ Live", configure DNS:

1. Go to **https://dash.cloudflare.com/infovotoperu.com/dns/records**
2. Add these CNAME records:

| Type | Name | Content | Proxy |
|------|------|---------|-------|
| CNAME | @ | `web-<hash>.us-central1.run.app` | 🟠 ON |
| CNAME | api | `gateway-<hash>.us-central1.run.app` | 🟠 ON |

3. **SSL/TLS** → set to **Full** (NOT Full Strict)
4. Wait ~5 min for DNS to propagate
5. Test:
```bash
curl https://infovotoperu.com
curl https://api.infovotoperu.com/health
```

## 5️⃣ Set Up Cloud Build (GitHub CI/CD)

Once verified, **in GCP Console:**

1. Go to **Cloud Build → Repositories**
2. Click **"2nd Gen" → "Connect Repository"**
3. Select **"GitHub"** → authorize with **cristian2023ml@gmail.com**
4. Select org: **iDeepBrain** and repos: **infovoto-web, infovoto-gateway, infovoto-mcp**
5. Create **3 Cloud Build Triggers** (one per repo):

**For infovoto-web:**
- Name: `infovoto-web-deploy`
- Repository: `infovoto-web`
- Branch: `^main$`
- Build type: `Cloud Run`
- Service name: `web`
- Region: `us-central1`

**For infovoto-gateway:**
- Name: `infovoto-gateway-deploy`
- Repository: `infovoto-gateway`
- Service name: `gateway`

**For infovoto-mcp:**
- Name: `infovoto-mcp-deploy`
- Repository: `infovoto-mcp`
- Service name: `mcp-server`

6. Test trigger: push a test commit to `main` → should auto-deploy

## 6️⃣ Verify GitHub Actions (Local)

After Cloud Build is set up:

```bash
# Make a test change in infovoto-web
cd infovoto-web
echo "# test commit" >> README.md
git add README.md
git commit -m "test: trigger cloud build"
git push origin main

# Check GCP Console:
# https://console.cloud.google.com/cloud-build/builds
# Should see a new build in progress (5-10 min)

# After build completes, check Web service:
# https://console.cloud.google.com/run/detail/us-central1/web
# Revision should be updated
```

## 7️⃣ Production Gate Tests

Run smoke tests to verify production config:

```bash
cd /Users/cristian/Documents/Proyectos/InfovotoProject/infovoto-gateway

pytest tests/smoke/test_smoke.py -v

# Should see 7 tests passing:
# ✅ test_environment_is_production
# ✅ test_docs_hidden_in_production
# ✅ test_auth_bypass_blocked
# ✅ test_cors_evil_origin_blocked
# ✅ test_cors_infovoto_allowed
# ✅ test_all_mcps_connected
# ✅ test_malformed_token_returns_401
```

## ⚠️ If Something Fails

**Build timeout?**
```bash
gcloud builds log <BUILD_ID> --region=us-central1 --limit=100
```

**Service not responding?**
```bash
gcloud run services describe web --region=us-central1
# Check status.conditions
```

**Environment vars missing?**
```bash
gcloud run services describe gateway --region=us-central1 --format=json | jq .spec.template.spec.containers[0].env
```

**Rollback to previous version:**
```bash
gcloud run services update web --region=us-central1 --revision=web-00001
```

---

**Next:** Once all checks pass, your production is live! New pushes to `main` will auto-deploy via Cloud Build.
