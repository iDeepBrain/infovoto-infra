# Autenticación — InfoVoto

## Resumen

3 capas de autenticación + 3 capas de protección anti-abuso.

```
Browser → Next.js proxy (agrega API key) → Gateway (valida Bearer + API key) → Agente
Gradio  → Gateway directo (X-API-Key) → Agente
WhatsApp → Gateway (HMAC-SHA256) → Agente
```

---

## Flujos de Autenticación

### 1. Web (Browser → Next.js → Gateway)

```
┌─────────┐    POST /api/chat     ┌──────────────┐   Bearer + X-API-Key   ┌─────────┐
│ Browser │ ──────────────────── → │ Next.js      │ ────────────────────── → │ Gateway │
│         │   (sin auth headers)  │ Proxy        │   (server-side)        │         │
│         │                       │ route.ts     │                        │         │
└─────────┘                       └──────────────┘                        └─────────┘
     │                                  │                                      │
     │ 1. Login Google OAuth            │ 2. getServerSession()                │ 3. Valida:
     │    → NextAuth guarda             │    → obtiene id_token                │    - Bearer token (Google)
     │      id_token en session         │    → lee GATEWAY_API_KEY_WEB         │    - X-API-Key (dict lookup)
     │                                  │    → forward con ambos headers       │    → AuthUser(user_id, role)
```

**Archivos:**
- `infovoto-web/lib/api.ts` — browser llama `/api/chat` local (sin auth)
- `infovoto-web/app/api/chat/route.ts` — proxy server-side (40 líneas)
- `infovoto-web/lib/auth.ts` — NextAuth config (Google OAuth + token refresh)
- `infovoto-gateway/src/gateway/auth.py` — FastAPI `Depends(get_current_user)`

**Seguridad:**
- API key NUNCA visible en browser (server-side only)
- Google token se refresca automáticamente (NextAuth `jwt` callback)
- DevTools/Inspect no muestra la API key

### 2. Gradio (Directo al Gateway)

```
┌─────────┐   X-API-Key: gk_gradio_...   ┌─────────┐
│ Gradio  │ ─────────────────────────── → │ Gateway │
│         │   POST /webhook/test          │         │
└─────────┘                               └─────────┘
```

**Configuración en Gradio:**
```python
headers = {"X-API-Key": os.environ["GATEWAY_API_KEY_GRADIO"]}
response = httpx.post(f"{GATEWAY_URL}/webhook/test", headers=headers, json={...})
```

### 3. WhatsApp (HMAC-SHA256)

```
┌──────────┐   X-Hub-Signature-256: sha256=...   ┌─────────┐
│ Meta     │ ──────────────────────────────────── → │ Gateway │
│ Webhook  │   POST /webhook                      │         │
└──────────┘                                       └─────────┘
```

**Verificación:** `hmac.compare_digest(expected_sig, received_sig)` — timing-safe.

### 4. Tests (Dev Only)

```
┌──────────┐   X-Test-User-Id: test123   ┌─────────┐
│ curl/    │ ──────────────────────── → │ Gateway │
│ pytest   │   POST /api/chat            │ (dev)   │
└──────────┘                             └─────────┘
```

Solo funciona cuando `ENVIRONMENT=development`. En producción se ignora.

---

## API Keys

### Generación

```bash
python3 -c "import secrets; print(f'gk_gradio_{secrets.token_hex(16)}')"
```

### Almacenamiento

| Archivo | Variable | Usado por |
|---------|----------|-----------|
| `.env.secrets` | `API_KEY_GRADIO` | Gateway (Pydantic Settings) |
| `.env.secrets` | `API_KEY_WEB` | Gateway (Pydantic Settings) |
| `.env.secrets` | `API_KEY_ADMIN` | Gateway (Pydantic Settings) |
| `infovoto-web/.env.local` | `GATEWAY_API_KEY_WEB` | Web proxy (Next.js) |

### Roles

| Key | Role | Permisos |
|-----|------|----------|
| `gk_gradio_...` | `service` | `/api/chat`, `/webhook/test` |
| `gk_web_...` | `service` | `/api/chat`, `/api/chat/stream` |
| `gk_admin_...` | `admin` | Todo |

### Validación (Gateway)

```python
# src/gateway/auth.py
from fastapi.security import APIKeyHeader

_api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)

async def get_current_user(api_key = Depends(_api_key_header), ...):
    # 1. API Key (O(1) dict lookup)
    # 2. Dev bypass (X-Test-User-Id)
    # 3. Google OAuth (Bearer token)
    # → AuthUser(user_id, role)
```

---

## Protección Anti-Abuso

### Capa 1: Rate Limit por IP

| Tipo | Límite | Ventana |
|------|:------:|:-------:|
| IP anónima | 60 req | 1 min |
| IP autenticada | 300 req | 1 min |

**Archivo:** `src/gateway/middleware/rate_limiter.py`
**Método:** Redis sliding window (sorted sets)

### Capa 2: Rate Limit por Usuario

| Tipo | Límite | Ventana |
|------|:------:|:-------:|
| Web user (Google sub) | 30 req | 1 hora |
| Service (API key) | Sin límite | — |
| Test (dev) | Sin límite | — |

**Archivo:** `src/gateway/auth.py` → `check_user_rate_limit()`

### Capa 3: Token Budget Diario

| Tipo | Límite |
|------|:------:|
| Web user | 50,000 tokens/día |
| Service | Sin límite |

**Archivo:** `src/gateway/routers/api.py`
**Key Redis:** `tokens:{user_id}:{fecha}` (TTL 24h)

### Capa 4: Input Validation

- Max message length: 4,000 caracteres
- Prompt injection detection (regex patterns)
- Output sanitization (URLs, XSS, stack traces)

**Archivos:**
- `src/agent/core.py` → `_check_prompt_injection()`
- `src/agent/output_filter.py` → `_sanitize_output()`

---

## Endpoints — Matriz de Auth

| Endpoint | Método | Auth requerida | Quién lo usa |
|----------|--------|:-------------:|-------------|
| `/api/chat` | POST | Bearer + API Key | Web (via proxy) |
| `/api/chat` | POST | API Key sola | Servicios directos |
| `/api/chat/stream` | POST | Bearer + API Key | Web (via proxy) |
| `/webhook` | GET | verify_token (WhatsApp) | Meta |
| `/webhook` | POST | HMAC-SHA256 | Meta |
| `/webhook/test` | POST | API Key (prod) / libre (dev) | Gradio |
| `/analytics/stats` | GET | Bearer o API Key | Web |
| `/analytics/daily-stats` | GET | Bearer o API Key | Web |
| `/health` | GET | Ninguna | Monitoreo |
| `/ready` | GET | Ninguna | Cloud Run probe |
| `/auth/verify` | POST | Ninguna (valida tokens) | Web login flow |
| `/docs` | GET | Ninguna (solo dev) | Swagger UI |

---

## Variables de Entorno

### Gateway (`infovoto-gateway`)

```bash
# Google OAuth
GOOGLE_CLIENT_ID=630531...apps.googleusercontent.com

# API Keys
API_KEY_GRADIO=gk_gradio_...
API_KEY_WEB=gk_web_...
API_KEY_ADMIN=gk_admin_...

# Rate limits
USER_RATE_LIMIT_PER_HOUR=30
USER_DAILY_TOKEN_BUDGET=50000

# WhatsApp
WHATSAPP_APP_SECRET=...    # HMAC verification
WHATSAPP_VERIFY_TOKEN=...  # Webhook setup
```

### Web (`infovoto-web`)

```bash
# Google OAuth (NextAuth)
GOOGLE_CLIENT_ID=630531...
GOOGLE_CLIENT_SECRET=GOCSPX-...
NEXTAUTH_SECRET=...
NEXTAUTH_URL=http://localhost:2300

# Gateway proxy (server-side only — NUNCA NEXT_PUBLIC_)
GATEWAY_URL=http://gateway:8080          # Docker internal
GATEWAY_API_KEY_WEB=gk_web_...           # API key server-side

# Browser (build-time, safe to expose)
NEXT_PUBLIC_GATEWAY_URL=http://localhost:2080  # Port mapping
```

---

## Docker Compose — Red Interna

```
┌─────────────────────────────────────────────────────────┐
│                   Docker Network                         │
│                                                         │
│  ┌──────────┐     ┌──────────┐     ┌──────────────┐    │
│  │ web      │────→│ gateway  │────→│ infovoto-mcp │    │
│  │ :3000    │     │ :8080    │     │ :8080        │    │
│  └──────────┘     └────┬─────┘     └──────────────┘    │
│                        │                                 │
│                   ┌────┴─────┐                          │
│                   │          │                           │
│              ┌────▼───┐ ┌───▼────┐                     │
│              │ redis  │ │postgres│                      │
│              │ :6379  │ │ :5432  │                      │
│              └────────┘ └────────┘                      │
│                                                         │
└─────────────────────────────────────────────────────────┘

Puertos externos (port mapping):
  web:      localhost:2300 → web:3000
  gateway:  localhost:2080 → gateway:8080
  mcp:      localhost:2900 → infovoto-mcp:8080
  postgres: localhost:2432 → postgres:5432
  redis:    localhost:2379 → redis:6379
```

---

## Para GCP Cloud Run

Al deployar, agregar como secrets en Cloud Run:

```bash
# Gateway service
gcloud run services update infovoto-gateway \
  --set-secrets=API_KEY_GRADIO=api-key-gradio:latest \
  --set-secrets=API_KEY_WEB=api-key-web:latest \
  --set-secrets=API_KEY_ADMIN=api-key-admin:latest \
  --set-secrets=GOOGLE_CLIENT_ID=google-client-id:latest

# Web service
gcloud run services update infovoto-web \
  --set-secrets=GATEWAY_API_KEY_WEB=api-key-web:latest \
  --set-env-vars=GATEWAY_URL=https://infovoto-gateway-xxx.run.app
```

Los secrets se crean primero en Secret Manager:
```bash
echo -n "gk_web_..." | gcloud secrets create api-key-web --data-file=-
```
