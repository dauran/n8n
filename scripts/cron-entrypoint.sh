#!/bin/sh
# Entrypoint for the `backup` sidecar: installs what backup.sh needs, then launches crond.

set -eu

if [ -z "${BACKUP_CRON:-}" ]; then
  echo "BACKUP_CRON is empty — automatic backups disabled. Sleeping."
  exec sleep infinity
fi

# docker:cli is alpine-based; backup.sh uses bash + GNU date.
apk add --no-cache bash coreutils >/dev/null 2>&1

# Cron runs commands with a minimal env. Bake the needed values into a wrapper.
WRAPPER=/usr/local/bin/run-backup
cat > "$WRAPPER" <<EOF
#!/bin/sh
export HOST_PROJECT_ROOT='${HOST_PROJECT_ROOT:-}'
export COMPOSE_PROJECT_NAME='${COMPOSE_PROJECT_NAME:-}'
cd /app
exec /app/scripts/backup.sh
EOF
chmod +x "$WRAPPER"

mkdir -p /etc/crontabs
echo "${BACKUP_CRON} ${WRAPPER} >> /proc/1/fd/1 2>&1" > /etc/crontabs/root

echo "backup cron installed: '${BACKUP_CRON}'"
exec crond -f -l 2
