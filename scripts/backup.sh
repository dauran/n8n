#!/usr/bin/env bash
set -euo pipefail

# Backup the n8n stack (Postgres dump + n8n_storage volume) into .backup/<timestamp>/.
# .env is NOT included — keep N8N_ENCRYPTION_KEY safe on your own.

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker not found in PATH" >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "error: 'docker compose' plugin not available" >&2
  exit 1
fi

if [ ! -f "$ROOT/.env" ]; then
  echo "error: .env not found in $ROOT" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source "$ROOT/.env"
set +a

: "${POSTGRES_USER:?POSTGRES_USER missing in .env}"
: "${POSTGRES_DB:?POSTGRES_DB missing in .env}"

PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$ROOT")}"
N8N_VOLUME="${PROJECT}_n8n_storage"

if ! docker volume inspect "$N8N_VOLUME" >/dev/null 2>&1; then
  echo "error: volume '$N8N_VOLUME' does not exist — is the stack initialized?" >&2
  exit 1
fi

# pg_dump requires postgres to be running
if [ -z "$(docker compose ps -q postgres 2>/dev/null)" ]; then
  echo "postgres service not running — starting it..."
  docker compose up -d postgres
  echo -n "waiting for postgres to be healthy"
  until docker compose exec -T postgres pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; do
    echo -n "."
    sleep 1
  done
  echo " ok"
fi

TS="$(date +%Y%m%d-%H%M%S)"
DEST="$ROOT/.backup/$TS"
mkdir -p "$DEST"

echo "→ dumping postgres database '$POSTGRES_DB'..."
docker compose exec -T postgres pg_dump \
  -U "$POSTGRES_USER" \
  -d "$POSTGRES_DB" \
  --clean --if-exists --format=custom \
  | gzip > "$DEST/postgres.dump.gz"

echo "→ archiving n8n volume '$N8N_VOLUME'..."
docker run --rm \
  -v "$N8N_VOLUME:/data:ro" \
  -v "$DEST:/backup" \
  alpine tar czf /backup/n8n_storage.tgz -C /data .

echo "→ writing manifest..."
{
  echo "timestamp: $TS"
  echo "project: $PROJECT"
  echo "n8n_volume: $N8N_VOLUME"
  echo "postgres_db: $POSTGRES_DB"
  echo ""
  echo "images:"
  docker compose images --format '  {{.Service}}: {{.Repository}}:{{.Tag}}' 2>/dev/null || true
  echo ""
  echo "files (size / sha256):"
  for f in postgres.dump.gz n8n_storage.tgz; do
    size="$(wc -c < "$DEST/$f" | tr -d ' ')"
    sum="$(shasum -a 256 "$DEST/$f" | awk '{print $1}')"
    echo "  $f  ${size} bytes  $sum"
  done
} > "$DEST/manifest.txt"

echo ""
echo "✔ Backup written to $DEST"
echo "⚠ .env is NOT in the backup — store N8N_ENCRYPTION_KEY and Postgres passwords"
echo "  separately (secret manager, 1Password, …). Without them, restore is useless."
