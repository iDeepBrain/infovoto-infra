#!/usr/bin/env bash
# sync-env.sh — agrega keys FALTANTES al .env.config raíz desde los .env.config.example
# NUNCA lee ni modifica valores existentes. Solo appende keys nuevas.
# NUNCA toca .env.secrets — esas keys se gestionan manualmente.
#
# Uso:
#   ./scripts/env/sync-env.sh
#   ./scripts/env/sync-env.sh /ruta/a/.env.config

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
ENV_FILE="${1:-$ROOT/.env.config}"

RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'; BLU='\033[0;34m'; NC='\033[0m'

echo ""
echo -e "${BLU}══════════════════════════════════════════${NC}"
echo -e "${BLU}  InfoVoto — sync .env.config${NC}"
echo -e "${BLU}══════════════════════════════════════════${NC}"
echo -e "  Destino: ${ENV_FILE}"
echo ""

# Crear .env si no existe
if [[ ! -f "$ENV_FILE" ]]; then
    touch "$ENV_FILE"
    echo -e "${YEL}  Creado nuevo: $ENV_FILE${NC}"
fi

EXAMPLES=(
    "$ROOT/.env.config.example"
    "$ROOT/infovoto-infra/.env.config.example"
    "$ROOT/infovoto-gateway/.env.config.example"
    "$ROOT/infovoto-mcp/.env.config.example"
    "$ROOT/infovoto-scraper/.env.config.example"
)

ADDED=0
SKIPPED=0
SEEN=""

for example in "${EXAMPLES[@]}"; do
    [[ ! -f "$example" ]] && continue
    repo=$(basename "$(dirname "$example")")

    while IFS= read -r line; do
        # Ignorar comentarios y vacías
        [[ "$line" =~ ^\s*# ]] && continue
        [[ -z "${line// }" ]] && continue
        [[ "$line" != *=* ]] && continue

        key=$(echo "$line" | cut -d'=' -f1 | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        [[ -z "$key" ]] && continue

        # Saltar duplicados entre examples
        if echo "$SEEN" | grep -qx "$key"; then
            continue
        fi
        SEEN="$SEEN
$key"

        # ¿Ya existe en el .env real?
        if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
            SKIPPED=$((SKIPPED + 1))
            continue
        fi

        # Agregar al .env con valor vacío (o default seguro)
        default_val=$(echo "$line" | cut -d'=' -f2-)
        # Si el valor del example parece real/secreto, dejarlo vacío
        case "$default_val" in
            *your-*|*xxxx*|*change-me*|*generate*|AIza*|GOCSPX*)
                default_val=""
                ;;
        esac

        echo "${key}=${default_val}" >> "$ENV_FILE"
        echo -e "  ${GRN}+ ${key}${NC}  ← agregado (de $repo)"
        ADDED=$((ADDED + 1))
    done < "$example"
done

echo ""
if [[ $ADDED -eq 0 ]]; then
    echo -e "${GRN}✓ Sin cambios — .env ya tenía todas las keys${NC}"
else
    echo -e "${GRN}✓ $ADDED keys agregadas, $SKIPPED ya existían${NC}"
    echo -e "${YEL}  Revisa y completa los valores vacíos en: ${ENV_FILE}${NC}"
fi
echo ""
echo -e "${BLU}══════════════════════════════════════════${NC}"
echo ""
