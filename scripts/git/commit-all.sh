#!/usr/bin/env bash
# commit-all.sh — commitea y pushea todos los repos de InfoVoto con un mensaje
# Uso: ./scripts/git/commit-all.sh "mensaje del commit"

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

if [ -z "${1:-}" ]; then
  echo "❌  Uso: $0 \"mensaje del commit\""
  exit 1
fi

MESSAGE="$1"

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
    echo "⚠️  $repo — sin git, saltando"
    continue
  fi

  cd "$DIR"
  CHANGES=$(git status --porcelain | wc -l | tr -d ' ')

  if [ "$CHANGES" -eq 0 ]; then
    echo "✅  $repo — nada que commitear"
    continue
  fi

  echo "📦  $repo — commiteando $CHANGES archivo(s)..."
  git config user.name "CristianLazoQuispe"
  git config user.email "mecatronico.lazo@gmail.com"
  git add .
  git commit -m "$MESSAGE

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
  git push origin "$(git rev-parse --abbrev-ref HEAD)"
  echo "✅  $repo — pusheado"
done

echo ""
echo "🚀  Todos los repos procesados."
