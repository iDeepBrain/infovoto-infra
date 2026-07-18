#!/bin/bash
# ============================================================================
# 🦊 InfoVoto Perú 2026 — GCP + Cloudflare Setup (Mejorado)
# ============================================================================
# Setup completo: APIs, Service Account, Secrets, Cloud Run, DNS
# SEGURO: paso a paso, idempotente, sin eliminar recursos existentes
#
# USO:
#   chmod +x setup-gcp-production.sh
#   ./setup-gcp-production.sh
#
# REQUISITOS:
#   - gcloud CLI v445+
#   - Cuenta GCP con billing habilitado
#   - Dominio en Cloudflare (opcional)
# ============================================================================

set -e

# ─── COLORES ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# ─── HELPERS ─────────────────────────────────────────────────────────────────
step() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${PURPLE}$1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}
ok() { echo -e "${GREEN}✅ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; exit 1; }
info() { echo -e "${BLUE}ℹ️  $1${NC}"; }

# ─── PASO 0: PRE-REQUISITOS ─────────────────────────────────────────────────
step "PASO 0: Verificando pre-requisitos"

# gcloud
if ! command -v gcloud &> /dev/null; then
    fail "gcloud CLI no instalado. Ve a: https://cloud.google.com/sdk/docs/install"
fi
ok "gcloud instalado: $(gcloud --version 2>/dev/null | grep '^Google Cloud SDK' | head -1)"

# Verificar autenticación
if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q .; then
    warn "No hay cuenta GCP autenticada. Abriendo browser para login..."
    gcloud auth login
fi
ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)")
ok "Autenticado como: $ACCOUNT"

# ─── PASO 1: CONFIGURACIÓN INTERACTIVA ───────────────────────────────────────
step "PASO 1: Configuración (input interactivo)"

# PROJECT_ID
read -p "🔹 PROJECT_ID en GCP (ej: infovoto-2026): " PROJECT_ID
if [ -z "$PROJECT_ID" ]; then
    fail "PROJECT_ID es requerido"
fi

# REGION
read -p "🔹 REGION (ej: us-central1 = más barato): " REGION
REGION="${REGION:-us-central1}"

# DOMAIN
read -p "🔹 Dominio (ej: infovoto.pe, o dejar vacío): " DOMAIN

# Nombre del service account
SA_NAME="infovoto-deployer"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# Directorios
WEB_DIR="./infovoto-web"
GATEWAY_DIR="./infovoto-gateway"
MCP_DIR="./infovoto-mcp"

# Resumen
echo ""
info "Resumen de configuración:"
echo "   PROJECT_ID: $PROJECT_ID"
echo "   REGION: $REGION"
echo "   DOMAIN: ${DOMAIN:-(opcional)}"
echo "   SA_EMAIL: $SA_EMAIL"
echo ""
read -p "¿Continuar? (s/n): " CONTINUE
if [ "$CONTINUE" != "s" ] && [ "$CONTINUE" != "S" ]; then
    echo "Cancelado."
    exit 0
fi

# ─── PASO 2: SET PROJECT ────────────────────────────────────────────────────
step "PASO 2: Configurar proyecto"

gcloud config set project "$PROJECT_ID" --quiet
ok "Proyecto seteado: $PROJECT_ID"

# Verificar billing
BILLING=$(gcloud billing projects describe "$PROJECT_ID" --format="value(billingEnabled)" 2>/dev/null || echo "false")
if [ "$BILLING" != "True" ]; then
    fail "Billing NO habilitado. Ve a: https://console.cloud.google.com/billing/linkedaccount?project=$PROJECT_ID"
fi
ok "Billing habilitado"

# ─── PASO 3: HABILITAR APIs ─────────────────────────────────────────────────
step "PASO 3: Habilitar APIs"

APIS=(
    "run.googleapis.com"
    "artifactregistry.googleapis.com"
    "cloudbuild.googleapis.com"
    "secretmanager.googleapis.com"
    "cloudresourcemanager.googleapis.com"
)

for api in "${APIS[@]}"; do
    echo -n "   $api... "
    gcloud services enable "$api" --quiet 2>/dev/null && echo -e "${GREEN}✅${NC}" || echo -e "${YELLOW}(ya habilitada)${NC}"
done
ok "APIs habilitadas"

# ─── PASO 4: SERVICE ACCOUNT ─────────────────────────────────────────────────
step "PASO 4: Service Account (para CI/CD)"

if gcloud iam service-accounts describe "$SA_EMAIL" --quiet &>/dev/null; then
    ok "Service account ya existe: $SA_EMAIL"
else
    gcloud iam service-accounts create "$SA_NAME" \
        --display-name="InfoVoto Deployer" \
        --quiet
    ok "Service account creado: $SA_EMAIL"
fi

# Asignar roles
ROLES=(
    "roles/run.admin"
    "roles/cloudbuild.builds.editor"
    "roles/artifactregistry.admin"
    "roles/iam.serviceAccountUser"
    "roles/secretmanager.secretAccessor"
)

for role in "${ROLES[@]}"; do
    echo -n "   $role... "
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:${SA_EMAIL}" \
        --role="$role" \
        --quiet 2>/dev/null && echo -e "${GREEN}✅${NC}" || echo -e "${YELLOW}(ya asignado)${NC}"
done
ok "Roles asignados"

# Generar key (solo si no existe)
KEY_FILE="./infovoto-sa-key.json"
if [ ! -f "$KEY_FILE" ]; then
    gcloud iam service-accounts keys create "$KEY_FILE" \
        --iam-account="$SA_EMAIL" \
        --quiet
    ok "Clave JSON generada: $KEY_FILE"
    warn "NUNCA subas esto a Git"
    echo "infovoto-sa-key.json" >> .gitignore 2>/dev/null || echo "infovoto-sa-key.json" > .gitignore
else
    ok "Clave ya existe: $KEY_FILE"
fi

# ─── PASO 5: SECRETS EN SECRET MANAGER ───────────────────────────────────────
step "PASO 5: Configurar Secrets"

echo "Ingresa tus secretos (presiona ENTER para saltear):"
echo ""

# GOOGLE_CLIENT_ID
GOOGLE_CLIENT_ID=$(gcloud secrets versions access latest --secret="GOOGLE_CLIENT_ID" 2>/dev/null || echo "")
if [ -z "$GOOGLE_CLIENT_ID" ]; then
    read -p "🔹 GOOGLE_CLIENT_ID (Google OAuth): " GOOGLE_CLIENT_ID
    if [ -n "$GOOGLE_CLIENT_ID" ]; then
        echo -n "$GOOGLE_CLIENT_ID" | gcloud secrets create "GOOGLE_CLIENT_ID" \
            --data-file=- \
            --replication-policy="automatic" \
            --quiet 2>/dev/null || gcloud secrets versions add "GOOGLE_CLIENT_ID" --data-file=- <<< "$GOOGLE_CLIENT_ID"
        ok "GOOGLE_CLIENT_ID guardado"
    fi
else
    ok "GOOGLE_CLIENT_ID ya existe"
fi

# GOOGLE_CLIENT_SECRET
GOOGLE_CLIENT_SECRET=$(gcloud secrets versions access latest --secret="GOOGLE_CLIENT_SECRET" 2>/dev/null || echo "")
if [ -z "$GOOGLE_CLIENT_SECRET" ]; then
    read -p "🔹 GOOGLE_CLIENT_SECRET: " GOOGLE_CLIENT_SECRET
    if [ -n "$GOOGLE_CLIENT_SECRET" ]; then
        echo -n "$GOOGLE_CLIENT_SECRET" | gcloud secrets create "GOOGLE_CLIENT_SECRET" \
            --data-file=- \
            --replication-policy="automatic" \
            --quiet 2>/dev/null || gcloud secrets versions add "GOOGLE_CLIENT_SECRET" --data-file=- <<< "$GOOGLE_CLIENT_SECRET"
        ok "GOOGLE_CLIENT_SECRET guardado"
    fi
else
    ok "GOOGLE_CLIENT_SECRET ya existe"
fi

# GEMINI_API_KEY
GEMINI_API_KEY=$(gcloud secrets versions access latest --secret="GEMINI_API_KEY" 2>/dev/null || echo "")
if [ -z "$GEMINI_API_KEY" ]; then
    read -p "🔹 GEMINI_API_KEY: " GEMINI_API_KEY
    if [ -n "$GEMINI_API_KEY" ]; then
        echo -n "$GEMINI_API_KEY" | gcloud secrets create "GEMINI_API_KEY" \
            --data-file=- \
            --replication-policy="automatic" \
            --quiet 2>/dev/null || gcloud secrets versions add "GEMINI_API_KEY" --data-file=- <<< "$GEMINI_API_KEY"
        ok "GEMINI_API_KEY guardado"
    fi
else
    ok "GEMINI_API_KEY ya existe"
fi

# NEXTAUTH_SECRET (generar si no existe)
if ! gcloud secrets describe "NEXTAUTH_SECRET" &>/dev/null 2>&1; then
    NEXTAUTH_SECRET=$(openssl rand -base64 32)
    echo -n "$NEXTAUTH_SECRET" | gcloud secrets create "NEXTAUTH_SECRET" \
        --data-file=- \
        --replication-policy="automatic" \
        --quiet
    ok "NEXTAUTH_SECRET generado: $NEXTAUTH_SECRET"
else
    ok "NEXTAUTH_SECRET ya existe"
fi

# ─── PASO 6: DEPLOY CLOUD RUN ───────────────────────────────────────────────
step "PASO 6: Deploy a Cloud Run"

deploy_service() {
    local name=$1
    local dir=$2
    local port=$3

    if [ ! -d "$dir" ]; then
        warn "Saltando $name — directorio no encontrado: $dir"
        return
    fi

    info "Deployando $name..."

    gcloud run deploy "$name" \
        --source="$dir" \
        --region="$REGION" \
        --platform=managed \
        --allow-unauthenticated \
        --port="$port" \
        --memory=512Mi \
        --cpu=0.5 \
        --max-instances=5 \
        --concurrency=100 \
        --quiet

    URL=$(gcloud run services describe "$name" --region="$REGION" --format="value(status.url)")
    ok "$name: $URL"
    echo "$name=$URL" >> .deploy-urls.tmp
}

rm -f .deploy-urls.tmp

deploy_service "web" "$WEB_DIR" 3000
deploy_service "gateway" "$GATEWAY_DIR" 8080
deploy_service "mcp-server" "$MCP_DIR" 8080

# Guardar URLs
if [ -f ".deploy-urls.tmp" ]; then
    mv .deploy-urls.tmp .deploy-urls
    ok "URLs guardadas en .deploy-urls"
fi

# ─── PASO 7: CONECTAR SECRETS ───────────────────────────────────────────────
step "PASO 7: Conectar Secrets a Cloud Run"

if gcloud run services describe "gateway" --region="$REGION" &>/dev/null 2>&1; then
    info "Conectando secrets al gateway..."

    gcloud run services update "gateway" \
        --region="$REGION" \
        --set-secrets="GOOGLE_CLIENT_ID=GOOGLE_CLIENT_ID:latest" \
        --set-secrets="GOOGLE_CLIENT_SECRET=GOOGLE_CLIENT_SECRET:latest" \
        --set-secrets="GEMINI_API_KEY=GEMINI_API_KEY:latest" \
        --set-secrets="NEXTAUTH_SECRET=NEXTAUTH_SECRET:latest" \
        --quiet 2>/dev/null || warn "Algunos secrets no se conectaron (revisar manualmente)"

    ok "Secrets conectados"
fi

# ─── PASO 8: CONFIGURAR ENV VARS ────────────────────────────────────────────
step "PASO 8: Configurar variables de entorno en Cloud Run"

# Gateway
gcloud run services update "gateway" \
    --region="$REGION" \
    --set-env-vars="ENVIRONMENT=production" \
    --set-env-vars="LOG_LEVEL=INFO" \
    --quiet

# Web
WEB_GATEWAY_URL=$(grep "^gateway=" .deploy-urls 2>/dev/null | cut -d= -f2)
gcloud run services update "web" \
    --region="$REGION" \
    --set-env-vars="NEXT_PUBLIC_GATEWAY_URL=$WEB_GATEWAY_URL" \
    --quiet

ok "Variables de entorno configuradas"

# ─── PASO 9: INSTRUCCIONES FINALES ──────────────────────────────────────────
step "✅ SETUP COMPLETADO"

echo ""
echo -e "${GREEN}┌───────────────────────────────────────────────────────────┐${NC}"
echo -e "${GREEN}│  🦊 InfoVoto Perú 2026 — Cloud Run Activo              │${NC}"
echo -e "${GREEN}│                                                           │${NC}"
if [ -f ".deploy-urls" ]; then
    while IFS='=' read -r name url; do
        printf "${GREEN}│  %-12s %s${NC}\n" "$name:" "$url"
    done < .deploy-urls
fi
echo -e "${GREEN}│                                                           │${NC}"
echo -e "${GREEN}│  💾 Service Account: $SA_EMAIL${NC}"
echo -e "${GREEN}│  🔑 Clave JSON: $KEY_FILE${NC}"
echo -e "${GREEN}│                                                           │${NC}"
echo -e "${GREEN}└───────────────────────────────────────────────────────────┘${NC}"
echo ""

if [ -n "$DOMAIN" ]; then
    echo -e "${YELLOW}📋 CONFIGURAR DNS EN CLOUDFLARE:${NC}"
    echo ""

    WEB_HOST=$(grep "^web=" .deploy-urls 2>/dev/null | cut -d= -f2 | sed 's|https://||')
    GW_HOST=$(grep "^gateway=" .deploy-urls 2>/dev/null | cut -d= -f2 | sed 's|https://||')

    echo "   Tipo   | Nombre | Contenido           | Proxy"
    echo "   -------|--------|---------------------|----------"
    echo "   CNAME  | @      | $WEB_HOST   | ON (🟠)"
    echo "   CNAME  | api    | $GW_HOST    | ON (🟠)"
    echo ""
    echo -e "${YELLOW}⚠️  SSL/TLS → Full (NO Full Strict)${NC}"
    echo ""
fi

echo -e "${YELLOW}📌 PRÓXIMOS PASOS:${NC}"
echo "   1. Configura DNS en Cloudflare (arriba)"
echo "   2. Espera 5-10 min para propagación"
echo "   3. Verifica: curl https://${DOMAIN:-tu-dominio.com}"
echo "   4. Para CI/CD: usa $KEY_FILE como GitHub Secret"
echo ""
