# Integración del Sistema — InfoVoto Perú 2026

Visión global de todos los servicios, sus responsabilidades y cómo se conectan.

---

## Arquitectura general

```
┌──────────────────────────────────────────────────────────────────┐
│                        Usuario final                              │
│                    (Browser / WhatsApp)                           │
└──────────────┬──────────────────────────────┬────────────────────┘
               │ HTTPS                         │ HTTPS (Meta)
               ▼                               ▼
┌──────────────────────┐           ┌──────────────────────┐
│   infovoto-web        │           │   Meta Webhook        │
│   Next.js 14          │           │   (WhatsApp Business) │
│   Cloud Run / Vercel  │           └──────────┬───────────┘
│   puerto 2300 (local) │                      │ HMAC-SHA256
└──────────┬───────────┘                       │
           │ Bearer + X-API-Key                │
           ▼                                   ▼
┌────────────────────────────────────────────────────────────────┐
│                     infovoto-gateway                             │
│                     FastAPI + Gemini Agent                       │
│                     Cloud Run Service — puerto 2080 (local)      │
│                                                                  │
│  Auth:  Google OAuth (id_token) + API Keys (dict lookup)        │
│  Rate:  IP middleware + per-user 30/hr + token budget 50k/día   │
│  Agent: InfoVotoAgent — Gemini 2.0 Flash + herramientas MCP     │
└──────────┬────────────────────────────┬───────────────────────-─┘
           │ HTTP (SSE para tools)       │ asyncpg / Redis
           ▼                             ▼
┌──────────────────────┐    ┌───────────────────────────────────┐
│   infovoto-mcp        │    │  PostgreSQL (Supabase en prod)    │
│   FastMCP             │    │  Redis (Upstash en prod)          │
│   5 herramientas      │    │  ChromaDB (embeddings ONNX)       │
│   Cloud Run Service   │    └───────────────────────────────────┘
│   puerto 2900 (local) │
│                       │
│  /perfiles   → JNE    │    ┌───────────────────────────────────┐
│  /planes     → JNE    │    │  infovoto-scraper                 │
│  /logistica  → ONPE   │    │  Batch job (local)                │
│  /fiscaliz.  → JNE    │    │  Llena PostgreSQL + ChromaDB      │
│  /financia.  → ONPE   │    │  Fuentes: JNE, ONPE, registros   │
└───────────────────────┘    └───────────────────────────────────┘
```

---

## Servicios

| Servicio | Tecnología | Deploy | Puerto local | Responsabilidad |
|----------|-----------|--------|:------------:|----------------|
| infovoto-web | Next.js 14 | Cloud Run / Vercel | 2300 | UI, auth proxy, analytics |
| infovoto-gateway | FastAPI + Gemini | Cloud Run | 2080 | Lógica de negocio, agente, auth |
| infovoto-mcp | FastMCP (5 apps) | Cloud Run | 2900 | Herramientas electorales |
| infovoto-scraper | Python batch | Job local | — | Ingesta de datos |
| PostgreSQL | Supabase (prod) | Managed | 2432 | Datos estructurados |
| Redis | Upstash (prod) | Managed | 2379 | Sessions, rate limit, cache |
| ChromaDB | Embedded | En gateway | — | Vectores planes/resoluciones |

---

## Flujo completo de una consulta

```
1. Browser → POST /api/chat (Next.js)
   - Sin auth headers (el browser no tiene la API key)

2. Next.js → POST /api/chat (Gateway)
   - Authorization: Bearer {id_token}
   - X-API-Key: gk_web_... (server-side only)
   - X-Real-IP: {client_ip}

3. Gateway Auth
   - Valida id_token con Google → obtiene user_id (sub)
   - Valida X-API-Key → rol "service"
   - check_user_rate_limit() → ≤30/hora → Redis

4. Gateway Agent (InfoVotoAgent)
   - Preprocessor: normaliza nicknames, DNI, saludos
   - LLM Router: decide si necesita herramientas MCP
   - Si sí → llama herramientas en infovoto-mcp
   - Synthesizer: construye respuesta final
   - Output filter: sanitiza URLs, XSS, stack traces

5. infovoto-mcp (si se usan herramientas)
   - Consulta PostgreSQL / ChromaDB
   - Devuelve datos estructurados al agente

6. Gateway → Next.js → Browser
   - { reply, sources, warnings, session_id, cached }
```

---

## Flujo de autenticación

```
Browser → Google OAuth → id_token
    → NextAuth guarda id_token en JWT de sesión
    → Al login: POST /auth/verify con id_token
    → Gateway valida con Google → devuelve user_id (Google sub)
    → user_id se almacena en NextAuth JWT
    → Cada /api/chat incluye id_token como Bearer
```

Ver detalle en:
- `infovoto-web/docs/technical/auth-flow.md`
- `infovoto-infra/docs/technical/autenticacion.md`

---

## Red Docker (local)

```
┌─────────────────────────────────────────────────────────┐
│                    Docker Network                         │
│                                                          │
│  ┌──────────┐    ┌──────────┐    ┌──────────────┐       │
│  │ web      │───▶│ gateway  │───▶│ infovoto-mcp │       │
│  │ :3000    │    │ :8080    │    │ :8080        │       │
│  └──────────┘    └────┬─────┘    └──────────────┘       │
│                       │                                  │
│                  ┌────┴────┐                             │
│             ┌────▼───┐ ┌───▼────┐                       │
│             │ redis  │ │postgres│                        │
│             │ :6379  │ │ :5432  │                        │
│             └────────┘ └────────┘                        │
└─────────────────────────────────────────────────────────┘

Puertos externos:
  web:      localhost:2300 → web:3000
  gateway:  localhost:2080 → gateway:8080
  mcp:      localhost:2900 → infovoto-mcp:8080
  postgres: localhost:2432 → postgres:5432
  redis:    localhost:2379 → redis:6379
```

Orquestación: `infovoto-infra/docker-compose.yml`

---

## Diagrama Mermaid

Ver: [diagrams/system-overview.mmd](diagrams/system-overview.mmd)
