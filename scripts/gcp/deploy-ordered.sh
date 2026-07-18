#!/bin/bash
# ============================================================================
# 🦊 Deploy CORRECTO: MCP → Gateway → Web
# Respeta dependencias y configura networking entre servicios
# ============================================================================

set -e

PROJECT_ID="proyectosia-423918"
REGION="us-central1"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

step() { echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n${PURPLE}$1${NC}\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; }
ok() { echo -e "${GREEN}✅ $1${NC}"; }
info() { echo -e "${BLUE}ℹ️  $1${NC}"; }

step "DEPLOY ORDENADO — Infovoto a Cloud Run"
info "Orden: MCP (sin deps) → Gateway (conecta a MCP) → Web (conecta a Gateway)"

# ─── PASO 1: MCP SERVER (SIN DEPENDENCIAS) ─────────────────────────────────
step "1️⃣  DEPLOY: MCP SERVER (sin dependencias)"

if [ ! -d "./infovoto-mcp" ]; then
    echo -e "${RED}❌ Directorio ./infovoto-mcp no encontrado${NC}"
    exit 1
fi

echo "   Deployando mcp-server..."
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

# ─── PASO 2: GATEWAY (DEPENDE DE MCP) ──────────────────────────────────────
step "2️⃣  DEPLOY: GATEWAY (conecta a MCP)"

if [ ! -d "./infovoto-gateway" ]; then
    echo -e "${RED}❌ Directorio ./infovoto-gateway no encontrado${NC}"
    exit 1
fi

echo "   Deployando gateway..."
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

# Conectar secrets al gateway
echo "   Conectando secrets..."
gcloud run services update gateway \
    --region=$REGION \
    --set-secrets="GOOGLE_CLIENT_ID=GOOGLE_CLIENT_ID:latest" \
    --set-secrets="GOOGLE_CLIENT_SECRET=GOOGLE_CLIENT_SECRET:latest" \
    --set-secrets="GEMINI_API_KEY=GEMINI_API_KEY:latest" \
    --set-secrets="NEXTAUTH_SECRET=NEXTAUTH_SECRET:latest" \
    --quiet

# Configurar env vars en gateway (MCP_URLS apunta a mcp-server)
echo "   Configurando networking..."
gcloud run services update gateway \
    --region=$REGION \
    --set-env-vars="ENVIRONMENT=production" \
    --set-env-vars="LOG_LEVEL=INFO" \
    --set-env-vars="MCP_URLS=$MCP_URL/perfiles,$MCP_URL/planes-gobierno,$MCP_URL/logistica,$MCP_URL/fiscalizacion,$MCP_URL/financiamiento" \
    --quiet

ok "Gateway conectado a MCP"

# ─── PASO 3: WEB (DEPENDE DE GATEWAY) ──────────────────────────────────────
step "3️⃣  DEPLOY: WEB (conecta a Gateway)"

if [ ! -d "./infovoto-web" ]; then
    echo -e "${RED}❌ Directorio ./infovoto-web no encontrado${NC}"
    exit 1
fi

echo "   Deployando web..."
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

# Configurar env vars en web (NEXT_PUBLIC_GATEWAY_URL apunta a gateway)
echo "   Configurando networking..."
gcloud run services update web \
    --region=$REGION \
    --set-env-vars="NEXT_PUBLIC_GATEWAY_URL=$GATEWAY_URL" \
    --quiet

ok "Web conectada a Gateway"

# ─── RESUMEN FINAL ────────────────────────────────────────────────────────
step "✅ DEPLOY COMPLETADO"

echo -e "${GREEN}┌───────────────────────────────────────────────────────────┐${NC}"
echo -e "${GREEN}│  🦊 InfoVoto Perú 2026 — VIVO EN CLOUD RUN           │${NC}"
echo -e "${GREEN}│                                                           │${NC}"
echo -e "${GREEN}│  MCP Server:${NC}"
printf "${GREEN}│    %s${NC}\n" "$MCP_URL"
echo -e "${GREEN}│                                                           │${NC}"
echo -e "${GREEN}│  Gateway (conecta a MCP):${NC}"
printf "${GREEN}│    %s${NC}\n" "$GATEWAY_URL"
echo -e "${GREEN}│                                                           │${NC}"
echo -e "${GREEN}│  Web (conecta a Gateway):${NC}"
printf "${GREEN}│    %s${NC}\n" "$WEB_URL"
echo -e "${GREEN}│                                                           │${NC}"
echo -e "${GREEN}└───────────────────────────────────────────────────────────┘${NC}"

# Guardar URLs
cat > .deploy-urls << EOF
mcp-server=$MCP_URL
gateway=$GATEWAY_URL
web=$WEB_URL
EOF

echo ""
echo -e "${YELLOW}📋 CONFIGURAR CLOUDFLARE DNS:${NC}"
echo ""

WEB_HOST=$(echo "$WEB_URL" | sed 's|https://||')
GW_HOST=$(echo "$GATEWAY_URL" | sed 's|https://||')

echo "   Ve a: https://dash.cloudflare.com/infovotoperu.com/dns/records"
echo ""
echo "   Agrega estos CNAME records:"
echo ""
echo "   Tipo   | Nombre | Contenido"
echo "   -------|--------|------------------"
echo "   CNAME  | @      | $WEB_HOST"
echo "   CNAME  | api    | $GW_HOST"
echo ""
echo -e "${YELLOW}   ⚠️  SSL/TLS → Full (NO Full Strict)${NC}"
echo ""

echo -e "${BLUE}🚀 VERIFICA EN ~5 MIN:${NC}"
echo "   curl https://infovotoperu.com"
echo "   curl https://api.infovotoperu.com/health"
echo ""

ok "¡Listo! Los servicios están conectados entre sí."
