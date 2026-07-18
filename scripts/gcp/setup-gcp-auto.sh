#!/bin/bash
# ============================================================================
# 🦊 InfoVoto Perú 2026 — Setup Automático (No-Interactivo)
# ============================================================================

set -e

# ─── CONFIG (SIN CAMBIOS NECESARIOS) ────────────────────────────────────────
PROJECT_ID="proyectosia-423918"
REGION="us-central1"
DOMAIN="infovotoperu.com"
SA_NAME="infovoto-deployer"

GOOGLE_CLIENT_ID="630531001367-e5ht0bfb6hj06vcirua1fg1grka4dvha.apps.googleusercontent.com"
GOOGLE_CLIENT_SECRET="GOCSPX-REPLACE-WITH-YOUR-VALUE"
GEMINI_API_KEY="AIza-REPLACE-WITH-YOUR-VALUE"
NEXTAUTH_SECRET=$(openssl rand -base64 32)

WEB_DIR="./infovoto-web"
GATEWAY_DIR="./infovoto-gateway"
MCP_DIR="./infovoto-mcp"

# ─── COLORES ────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

step() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${PURPLE}🦊 $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}
ok() { echo -e "${GREEN}✅ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; exit 1; }
info() { echo -e "${BLUE}ℹ️  $1${NC}"; }

# ─── PASO 0: VALIDACIONES ──────────────────────────────────────────────────
step "PASO 0: Validaciones"

if ! command -v gcloud &> /dev/null; then
    fail "gcloud no instalado"
fi
ok "gcloud listo"

if ! gcloud auth list --filter=status:ACTIVE 2>/dev/null | grep -q .; then
    fail "Debes hacer: gcloud auth login"
fi
ok "Autenticación OK"

# ─── PASO 1: CONFIG PROYECTO ──────────────────────────────────────────────
step "PASO 1: Configurar proyecto"

gcloud config set project "$PROJECT_ID" --quiet
ok "Proyecto: $PROJECT_ID"

BILLING=$(gcloud billing projects describe "$PROJECT_ID" --format="value(billingEnabled)" 2>/dev/null || echo "false")
[ "$BILLING" = "True" ] || fail "Billing no habilitado"
ok "Billing: OK"

# ─── PASO 2: APIS ────────────────────────────────────────────────────────
step "PASO 2: Habilitar APIs"

for api in run.googleapis.com artifactregistry.googleapis.com cloudbuild.googleapis.com secretmanager.googleapis.com; do
    echo -n "   $api... "
    gcloud services enable "$api" --quiet 2>/dev/null && echo -e "${GREEN}✅${NC}" || echo -e "${YELLOW}✓${NC}"
done
ok "APIs habilitadas"

# ─── PASO 3: SERVICE ACCOUNT ──────────────────────────────────────────────
step "PASO 3: Service Account"

SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

if ! gcloud iam service-accounts describe "$SA_EMAIL" --quiet &>/dev/null; then
    gcloud iam service-accounts create "$SA_NAME" \
        --display-name="InfoVoto Deployer" \
        --quiet
fi
ok "Service Account: $SA_EMAIL"

# Roles
for role in roles/run.admin roles/cloudbuild.builds.editor roles/artifactregistry.admin roles/iam.serviceAccountUser roles/secretmanager.secretAccessor; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:${SA_EMAIL}" \
        --role="$role" \
        --quiet 2>/dev/null || true
done
ok "Roles asignados"

# Key
KEY_FILE="./infovoto-sa-key.json"
if [ ! -f "$KEY_FILE" ]; then
    gcloud iam service-accounts keys create "$KEY_FILE" --iam-account="$SA_EMAIL" --quiet
    echo "infovoto-sa-key.json" >> .gitignore 2>/dev/null || echo "infovoto-sa-key.json" > .gitignore
    ok "Clave JSON: $KEY_FILE"
else
    ok "Clave ya existe"
fi

# ─── PASO 4: SECRETS ──────────────────────────────────────────────────────
step "PASO 4: Guardar Secrets en Secret Manager"

for secret_name in GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET GEMINI_API_KEY NEXTAUTH_SECRET; do
    secret_value="${!secret_name}"

    if ! gcloud secrets describe "$secret_name" &>/dev/null 2>&1; then
        echo -n "$secret_value" | gcloud secrets create "$secret_name" \
            --data-file=- \
            --replication-policy="automatic" \
            --quiet 2>/dev/null
        echo -e "   $secret_name... ${GREEN}creado${NC}"
    else
        echo -e "   $secret_name... ${YELLOW}existe${NC}"
    fi
done
ok "Secrets guardados"

# ─── PASO 5: DEPLOY CLOUD RUN ────────────────────────────────────────────
step "PASO 5: Deploy a Cloud Run"

deploy_service() {
    local name=$1
    local dir=$2
    local port=$3

    if [ ! -d "$dir" ]; then
        warn "Saltando $name — directorio no encontrado"
        return
    fi

    echo "   $name..."

    gcloud run deploy "$name" \
        --source="$dir" \
        --region="$REGION" \
        --platform=managed \
        --allow-unauthenticated \
        --port="$port" \
        --memory=512Mi \
        --cpu=0.5 \
        --max-instances=5 \
        --quiet 2>/dev/null || true

    URL=$(gcloud run services describe "$name" --region="$REGION" --format="value(status.url)" 2>/dev/null)
    ok "$name: $URL"
    echo "$name=$URL" >> .deploy-urls.tmp
}

rm -f .deploy-urls.tmp
deploy_service "web" "$WEB_DIR" 3000
deploy_service "gateway" "$GATEWAY_DIR" 8080
deploy_service "mcp-server" "$MCP_DIR" 8080

[ -f ".deploy-urls.tmp" ] && mv .deploy-urls.tmp .deploy-urls
ok "Servicios deployados"

# ─── PASO 6: CONECTAR SECRETS ────────────────────────────────────────────
step "PASO 6: Conectar Secrets a Cloud Run"

if gcloud run services describe "gateway" --region="$REGION" &>/dev/null 2>&1; then
    gcloud run services update "gateway" \
        --region="$REGION" \
        --set-secrets="GOOGLE_CLIENT_ID=GOOGLE_CLIENT_ID:latest" \
        --set-secrets="GOOGLE_CLIENT_SECRET=GOOGLE_CLIENT_SECRET:latest" \
        --set-secrets="GEMINI_API_KEY=GEMINI_API_KEY:latest" \
        --set-secrets="NEXTAUTH_SECRET=NEXTAUTH_SECRET:latest" \
        --quiet 2>/dev/null || true
    ok "Secrets conectados"
fi

# ─── PASO 7: ENV VARS ────────────────────────────────────────────────────
step "PASO 7: Variables de entorno"

gcloud run services update "gateway" \
    --region="$REGION" \
    --set-env-vars="ENVIRONMENT=production,LOG_LEVEL=INFO" \
    --quiet 2>/dev/null || true

if [ -f ".deploy-urls" ]; then
    WEB_GW_URL=$(grep "^gateway=" .deploy-urls 2>/dev/null | cut -d= -f2)
    gcloud run services update "web" \
        --region="$REGION" \
        --set-env-vars="NEXT_PUBLIC_GATEWAY_URL=$WEB_GW_URL" \
        --quiet 2>/dev/null || true
fi

ok "Variables seteadas"

# ─── RESUMEN ────────────────────────────────────────────────────────────
step "✅ SETUP COMPLETADO"

echo -e "${GREEN}┌─────────────────────────────────────────────────────────┐${NC}"
echo -e "${GREEN}│  🦊 InfoVoto Perú 2026 — Cloud Run Activo           │${NC}"
echo -e "${GREEN}│                                                         │${NC}"

if [ -f ".deploy-urls" ]; then
    while IFS='=' read -r name url; do
        printf "${GREEN}│  %-12s %s${NC}\n" "$name:" "$url"
    done < .deploy-urls
fi

echo -e "${GREEN}│                                                         │${NC}"
echo -e "${GREEN}│  🔧 Proyecto: $PROJECT_ID${NC}"
echo -e "${GREEN}│  🌍 Dominio: $DOMAIN${NC}"
echo -e "${GREEN}│  📍 Región: $REGION${NC}"
echo -e "${GREEN}│                                                         │${NC}"
echo -e "${GREEN}└─────────────────────────────────────────────────────────┘${NC}"

echo ""
echo -e "${YELLOW}📋 CONFIGURAR DNS EN CLOUDFLARE:${NC}"
echo ""

if [ -f ".deploy-urls" ]; then
    WEB_HOST=$(grep "^web=" .deploy-urls 2>/dev/null | cut -d= -f2 | sed 's|https://||')
    GW_HOST=$(grep "^gateway=" .deploy-urls 2>/dev/null | cut -d= -f2 | sed 's|https://||')

    echo "   Ve a: https://dash.cloudflare.com/"
    echo ""
    echo "   1. Selecciona dominio: $DOMAIN"
    echo "   2. DNS → Records"
    echo "   3. Agrega estos CNAME:"
    echo ""
    echo "      Nombre    Contenido                          Proxy"
    echo "      ────────  ─────────────────────────────────  ─────"
    echo "      @         $WEB_HOST    🟠 ON"
    echo "      api       $GW_HOST     🟠 ON"
    echo ""
    echo "   4. SSL/TLS → Full (NO Full Strict)"
    echo ""
fi

echo -e "${YELLOW}🚀 VERIFICA EN ~5 MIN:${NC}"
echo "   curl https://$DOMAIN"
echo "   curl https://api.$DOMAIN/health"
echo ""
