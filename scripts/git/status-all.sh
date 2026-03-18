#!/usr/bin/env bash
# status-all.sh — muestra el estado git de todos los repos de InfoVoto
# Uso: ./scripts/git/status-all.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

REPOS=(
  infovoto-gateway
  infovoto-mcp
  infovoto-web
  infovoto-scraper
  infovoto-infra
  infovoto-planning
  infovoto-docs
)

for repo in "${REPOS[@]}"; do
  DIR="$ROOT/$repo"
  if [ ! -d "$DIR/.git" ]; then
    echo "⚠️  $repo — sin git"
    continue
  fi

  cd "$DIR"
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
  CHANGES=$(git status --porcelain | wc -l | tr -d ' ')

  if [ "$CHANGES" -eq 0 ]; then
    echo "✅  $repo ($BRANCH) — limpio"
  else
    echo "📝  $repo ($BRANCH) — $CHANGES archivo(s) sin commitear"
    git status --short | sed 's/^/    /'
  fi
done
