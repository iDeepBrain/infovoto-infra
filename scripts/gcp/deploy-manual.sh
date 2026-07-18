#!/bin/bash
# Deploy manual de cada servicio (más robusto, con mejor debugging)

set -e

PROJECT_ID="proyectosia-423918"
REGION="us-central1"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
RED='\033[0;31m'
NC='\033[0m'

step() { echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n${PURPLE}$1${NC}\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; }
ok() { echo -e "${GREEN}✅ $1${NC}"; }

step "DEPLOY MANUAL — Infovoto a Cloud Run"

# ─── SERVICIO 1: WEB ───────────────────────────────────────────────────────
step "1️⃣  Deployando: WEB"

if [ ! -d "./infovoto-web" ]; then
    echo -e "${RED}❌ Directorio ./infovoto-web no encontrado${NC}"
    exit 1
fi

echo "   Construyendo y deployando web..."
gcloud run deploy web \
    --source=./infovoto-web \
    --region=$REGION \
    --platform=managed \
    --allow-unauthenticated \
    --port=3000 \
    --memory=512Mi \
    --cpu=0.5 \
    --max-instances=5 \
    --quiet

WEB_URL=$(gcloud run services describe web --region=$REGION --format="value(status.url)")
ok "WEB: $WEB_URL"
echo "web=$WEB_URL" >> .deploy-urls.tmp

# ─── SERVICIO 2: GATEWAY ──────────────────────────────────────────────────
step "2️⃣  Deployando: GATEWAY"

if [ ! -d "./infovoto-gateway" ]; then
    echo -e "${RED}❌ Directorio ./infovoto-gateway no encontrado${NC}"
    exit 1
fi

echo "   Construyendo y deployando gateway..."
gcloud run deploy gateway \
    --source=./infovoto-gateway \
    --region=$REGION \
    --platform=managed \
    --allow-unauthenticated \
    --port=8080 \
    --memory=512Mi \
    --cpu=0.5 \
    --max-instances=5 \
    --quiet

GATEWAY_URL=$(gcloud run services describe gateway --region=$REGION --format="value(status.url)")
ok "GATEWAY: $GATEWAY_URL"
echo "gateway=$GATEWAY_URL" >> .deploy-urls.tmp

# ─── SERVICIO 3: MCP ──────────────────────────────────────────────────────
step "3️⃣  Deployando: MCP-SERVER"

if [ ! -d "./infovoto-mcp" ]; then
    echo -e "${RED}❌ Directorio ./infovoto-mcp no encontrado${NC}"
    exit 1
fi

echo "   Construyendo y deployando mcp-server..."
gcloud run deploy mcp-server \
    --source=./infovoto-mcp \
    --region=$REGION \
    --platform=managed \
    --no-allow-unauthenticated \
    --port=8080 \
    --memory=512Mi \
    --cpu=0.5 \
    --max-instances=3 \
    --quiet

MCP_URL=$(gcloud run services describe mcp-server --region=$REGION --format="value(status.url)")
ok "MCP-SERVER: $MCP_URL"
echo "mcp-server=$MCP_URL" >> .deploy-urls.tmp

# ─── CONECTAR SECRETS ──────────────────────────────────────────────────────
step "4️⃣  Conectando Secrets"

gcloud run services update gateway \
    --region=$REGION \
    --set-secrets="GOOGLE_CLIENT_ID=GOOGLE_CLIENT_ID:latest" \
    --set-secrets="GOOGLE_CLIENT_SECRET=GOOGLE_CLIENT_SECRET:latest" \
    --set-secrets="GEMINI_API_KEY=GEMINI_API_KEY:latest" \
    --set-secrets="NEXTAUTH_SECRET=NEXTAUTH_SECRET:latest" \
    --quiet

ok "Secrets conectados al gateway"

# ─── CONFIGURAR ENV VARS ──────────────────────────────────────────────────
step "5️⃣  Configurar variables de entorno"

gcloud run services update gateway \
    --region=$REGION \
    --set-env-vars="ENVIRONMENT=production,LOG_LEVEL=INFO" \
    --quiet

gcloud run services update web \
    --region=$REGION \
    --set-env-vars="NEXT_PUBLIC_GATEWAY_URL=$GATEWAY_URL" \
    --quiet

ok "Variables de entorno seteadas"

# ─── RESUMEN FINAL ────────────────────────────────────────────────────────
step "✅ DEPLOY COMPLETADO"

if [ -f ".deploy-urls.tmp" ]; then
    mv .deploy-urls.tmp .deploy-urls

    echo -e "${GREEN}┌───────────────────────────────────────────────────────────┐${NC}"
    echo -e "${GREEN}│  🦊 InfoVoto Perú 2026 — VIVO EN CLOUD RUN           │${NC}"
    echo -e "${GREEN}│                                                           │${NC}"
    while IFS='=' read -r name url; do
        printf "${GREEN}│  %-12s %s${NC}\n" "$name:" "$url"
    done < .deploy-urls
    echo -e "${GREEN}│                                                           │${NC}"
    echo -e "${GREEN}└───────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${BLUE}📋 CONFIGURAR CLOUDFLARE DNS:${NC}"
    echo ""

    WEB_HOST=$(grep "^web=" .deploy-urls | cut -d= -f2 | sed 's|https://||')
    GW_HOST=$(grep "^gateway=" .deploy-urls | cut -d= -f2 | sed 's|https://||')

    echo "   Tipo   | Nombre | Contenido"
    echo "   -------|--------|------------------"
    echo "   CNAME  | @      | $WEB_HOST"
    echo "   CNAME  | api    | $GW_HOST"
    echo ""
    echo -e "${BLUE}   Ve a: https://dash.cloudflare.com/infovotoperu.com/dns/records${NC}"
fi

ok "¡Listo! Espera 5 min y verifica con: curl https://infovotoperu.com"
