#!/usr/bin/env bash
set -euo pipefail

# Restore an n8n backup produced by scripts/backup.sh.
# ⚠ Destructive: wipes the current Postgres database and n8n_storage volume.

usage() {
  echo "usage: $0 <backup-dir>" >&2
  echo "       e.g. $0 .backup/20260417-101530" >&2
  exit 1
}

[ $# -eq 1 ] || usage

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

BACKUP_ARG="$1"
# Resolve to absolute path
if [ -d "$BACKUP_ARG" ]; then
  BACKUP="$(cd "$BACKUP_ARG" && pwd)"
else
  echo "error: backup directory '$BACKUP_ARG' not found" >&2
  exit 1
fi

for f in postgres.dump.gz n8n_storage.tgz; do
  if [ ! -f "$BACKUP/$f" ]; then
    echo "error: missing '$f' in $BACKUP" >&2
    exit 1
  fi
done

if [ ! -f "$ROOT/.env" ]; then
  echo "error: .env not found in $ROOT — restore it first (needs N8N_ENCRYPTION_KEY)" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source "$ROOT/.env"
set +a

: "${POSTGRES_USER:?POSTGRES_USER missing in .env}"
: "${POSTGRES_DB:?POSTGRES_DB missing in .env}"
: "${POSTGRES_NON_ROOT_USER:?POSTGRES_NON_ROOT_USER missing in .env}"
: "${N8N_ENCRYPTION_KEY:?N8N_ENCRYPTION_KEY missing in .env (credentials would be unreadable)}"

PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$ROOT")}"
N8N_VOLUME="${PROJECT}_n8n_storage"

echo ""
echo "About to restore backup:"
echo "  source:    $BACKUP"
echo "  project:   $PROJECT"
echo "  postgres:  will DROP and reload database '$POSTGRES_DB'"
echo "  n8n:       will REPLACE contents of volume '$N8N_VOLUME'"
echo ""
echo "This is destructive. Type RESTORE (uppercase) to continue."
read -r CONFIRM
if [ "$CONFIRM" != "RESTORE" ]; then
  echo "aborted."
  exit 1
fi

echo "→ stopping stack and removing volumes..."
docker compose down -v

echo "→ starting postgres..."
docker compose up -d postgres
echo -n "  waiting for postgres to be healthy"
until docker compose exec -T postgres pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; do
  echo -n "."
  sleep 1
done
echo " ok"

echo "→ restoring postgres dump..."
gunzip -c "$BACKUP/postgres.dump.gz" \
  | docker compose exec -T postgres pg_restore \
      -U "$POSTGRES_USER" \
      -d "$POSTGRES_DB" \
      --clean --if-exists --no-owner --no-privileges

# pg_restore ran as POSTGRES_USER, so every restored object is now owned by that
# superuser. The n8n runtime connects as POSTGRES_NON_ROOT_USER — without
# ownership it cannot see the `migrations` table and boot-loops with
# "relation \"migrations\" already exists".
echo "→ reassigning public schema ownership to '$POSTGRES_NON_ROOT_USER'..."
docker compose exec -T postgres \
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 <<SQL
DO \$\$
DECLARE r record;
BEGIN
  FOR r IN SELECT tablename FROM pg_tables WHERE schemaname='public' LOOP
    EXECUTE format('ALTER TABLE public.%I OWNER TO %I', r.tablename, '$POSTGRES_NON_ROOT_USER');
  END LOOP;
  FOR r IN SELECT sequence_name FROM information_schema.sequences WHERE sequence_schema='public' LOOP
    EXECUTE format('ALTER SEQUENCE public.%I OWNER TO %I', r.sequence_name, '$POSTGRES_NON_ROOT_USER');
  END LOOP;
  FOR r IN SELECT table_name FROM information_schema.views WHERE table_schema='public' LOOP
    EXECUTE format('ALTER VIEW public.%I OWNER TO %I', r.table_name, '$POSTGRES_NON_ROOT_USER');
  END LOOP;
END \$\$;
SQL

echo "→ restoring n8n volume '$N8N_VOLUME'..."
# docker compose down -v removed the volume; starting postgres recreated only db_storage.
# Create n8n_storage explicitly if needed, then extract the tar into it.
docker volume create "$N8N_VOLUME" >/dev/null
docker run --rm \
  -v "$N8N_VOLUME:/data" \
  -v "$BACKUP:/backup:ro" \
  alpine sh -c "rm -rf /data/* /data/..?* /data/.[!.]* 2>/dev/null; tar xzf /backup/n8n_storage.tgz -C /data"

echo "→ starting full stack..."
docker compose up -d

echo ""
echo "✔ Restore complete."
echo "  Verify http://localhost:${N8N_PORT:-5678} — if credentials fail to decrypt,"
echo "  your current N8N_ENCRYPTION_KEY does not match the one used at backup time."
