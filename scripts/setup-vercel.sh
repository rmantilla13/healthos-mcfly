#!/usr/bin/env bash
# Sets every secret healthOS needs on Vercel (production). Run it yourself: it asks for your
# dashboard password, stores only a hash of it, and generates the other secrets.
#   bash scripts/setup-vercel.sh
set -euo pipefail
cd "$(dirname "$0")/.."
SCOPE=rickymantilla

command -v vercel >/dev/null || { echo "Install the Vercel CLI first: npm i -g vercel"; exit 1; }
[ -f .vercel/project.json ] || vercel link --yes --project healthos --scope "$SCOPE"

set_env() {
  vercel env rm "$1" production --yes --scope "$SCOPE" >/dev/null 2>&1 || true
  printf '%s' "$2" | vercel env add "$1" production --scope "$SCOPE" >/dev/null
  echo "  ✓ $1"
}

read -r -s -p "Choose your dashboard password (10+ characters): " PW; echo
read -r -s -p "Type it again: " PW2; echo
[ "$PW" = "$PW2" ] || { echo "Passwords don't match."; exit 1; }
HASH=$(HEALTHOS_PW="$PW" node scripts/hash-password.mjs)
unset PW PW2

echo "Setting secrets on Vercel…"
set_env HEALTHOS_PASSWORD_HASH "$HASH"
set_env SESSION_SECRET "$(openssl rand -hex 32)"
set_env CRON_SECRET "$(openssl rand -hex 32)"
INGEST=$(openssl rand -hex 24)
set_env HEALTHOS_INGEST_TOKEN "$INGEST"
set_env WHOOP_REDIRECT_URI "https://health.mcfly.bot/api/whoop/callback"

read -r -p "WHOOP client ID (Enter to skip for now): " WID
if [ -n "$WID" ]; then
  read -r -s -p "WHOOP client secret: " WSECRET; echo
  set_env WHOOP_CLIENT_ID "$WID"
  set_env WHOOP_CLIENT_SECRET "$WSECRET"
  unset WSECRET
fi

cat <<EOF

Done. Two more things:
  1. In the Vercel dashboard, open project "healthos" → Storage → Create Database → Neon (Postgres),
     and connect it to Production. That adds DATABASE_URL to the project.
  2. iOS companion app token (paste it into the app's settings; it's shown only now):
     $INGEST

Then deploy:  npm run deploy
EOF
