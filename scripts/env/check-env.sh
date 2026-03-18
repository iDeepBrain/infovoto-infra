#!/usr/bin/env bash
# check-env.sh — compara keys de los .env.example con el .env real
# NUNCA lee valores reales, solo nombres de variables.
#
# Uso:
#   ./scripts/env/check-env.sh                    # usa root .env por defecto
#   ./scripts/env/check-env.sh /ruta/a/.env       # especificar otro .env

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
ENV_FILE="${1:-$ROOT/.env.config}"

RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'; BLU='\033[0;34m'; NC='\033[0m'

echo ""
echo -e "${BLU}══════════════════════════════════════════${NC}"
echo -e "${BLU}  InfoVoto — verificación de .env.config${NC}"
echo -e "${BLU}══════════════════════════════════════════${NC}"
echo -e "  Verificando: ${ENV_FILE}"
echo ""

if [[ ! -f "$ENV_FILE" ]]; then
    echo -e "${RED}✗ No existe: $ENV_FILE${NC}"
    echo -e "  Crea uno con: cp .env.config.example $(dirname "$ENV_FILE")/.env.config"
    exit 1
fi

# Extrae solo los nombres de variables (ignora comentarios y vacías)
extract_keys() {
    grep -v '^\s*#' "$1" | grep -v '^\s*$' | grep '=' | cut -d'=' -f1 | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//'
}

ENV_KEYS=$(extract_keys "$ENV_FILE")

EXAMPLES=(
    "$ROOT/.env.config.example"
    "$ROOT/infovoto-infra/.env.config.example"
    "$ROOT/infovoto-gateway/.env.config.example"
    "$ROOT/infovoto-mcp/.env.config.example"
    "$ROOT/infovoto-scraper/.env.config.example"
)

SEEN=""   # lista de keys ya procesadas (separadas por newline)
MISSING=""
PRESENT=""

for example in "${EXAMPLES[@]}"; do
    [[ ! -f "$example" ]] && continue
    repo=$(basename "$(dirname "$example")")

    while IFS= read -r line; do
        [[ "$line" =~ ^\s*# ]] && continue
        [[ -z "${line// }" ]] && continue
        [[ "$line" != *=* ]] && continue

        key=$(echo "$line" | cut -d'=' -f1 | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        [[ -z "$key" ]] && continue

        # Saltar si ya la procesamos
        if echo "$SEEN" | grep -qx "$key"; then
            continue
        fi
        SEEN="$SEEN
$key"

        if echo "$ENV_KEYS" | grep -qx "$key"; then
            PRESENT="$PRESENT
✓ $key"
        else
            MISSING="$MISSING
✗ $key  ← falta (de $repo)"
        fi
    done < "$example"
done

# Mostrar presentes
if [[ -n "$PRESENT" ]]; then
    echo -e "${GRN}Keys presentes:${NC}"
    echo "$PRESENT" | grep -v '^$' | while IFS= read -r line; do
        echo -e "  ${GRN}${line}${NC}"
    done
    echo ""
fi

# Mostrar faltantes
if [[ -z "$MISSING" ]]; then
    echo -e "${GRN}✓ .env completo — no faltan keys${NC}"
else
    echo -e "${RED}Keys faltantes:${NC}"
    echo "$MISSING" | grep -v '^$' | while IFS= read -r line; do
        echo -e "  ${RED}${line}${NC}"
    done
    echo ""
    echo -e "${YEL}Agrega las keys faltantes a: ${ENV_FILE}${NC}"
    echo -e "${YEL}Copia el formato desde los .env.example (cambia el valor, no el key)${NC}"
fi

echo ""
echo -e "${BLU}══════════════════════════════════════════${NC}"
echo ""
