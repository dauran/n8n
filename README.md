# n8n — Docker Installation

Self-hosted [n8n](https://n8n.io/) stack with **PostgreSQL**, deployed via Docker Compose.

## Requirements

- [Docker](https://docs.docker.com/get-docker/) ≥ 24
- [Docker Compose](https://docs.docker.com/compose/) v2 (bundled with Docker Desktop)

## Quick start

```bash
# 1. Copy the environment template
cp .env.example .env

# 2. Replace the `replace_me_*` values with strong secrets
#    (generation examples)
openssl rand -hex 24   # Postgres passwords
openssl rand -hex 32   # N8N_ENCRYPTION_KEY

# 3. Start the stack
docker compose up -d

# 4. Follow the logs (Ctrl+C to exit)
docker compose logs -f n8n
```

n8n is then available at [http://localhost:5678](http://localhost:5678).
On first launch, create your owner account through the UI.

## Useful commands

```bash
docker compose ps              # service status
docker compose logs -f n8n     # n8n logs
docker compose stop            # stop (data preserved)
docker compose down            # stop + remove containers
docker compose down -v         # ⚠️ also removes volumes (DB + workflows)
docker compose pull && docker compose up -d   # upgrade
```

## Layout

```
.
├── docker-compose.yml   # n8n + postgres services
├── scripts/
│   ├── init-data.sh         # creates the application Postgres user on first boot
│   ├── backup.sh            # on-demand / scheduled backup
│   ├── restore.sh           # restore from a backup
│   ├── prune.sh             # applies the backup retention policy
│   └── cron-entrypoint.sh   # entrypoint for the backup cron sidecar
├── .env.example         # configuration template (committed)
├── .env                 # local configuration (gitignored — never commit)
├── .gitignore
├── LICENSE
└── README.md
```

## Configuration

All variables live in `.env` (see `.env.example` for the annotated reference).

| Variable | Purpose |
|---|---|
| `N8N_VERSION` | n8n image tag (`latest`, or e.g. `1.75.2` — pin in production) |
| `N8N_ENCRYPTION_KEY` | **Critical.** Encrypts stored credentials. Never change after the first boot |
| `POSTGRES_*` | Postgres credentials (root + application user `n8n`) |
| `N8N_HOST` / `N8N_PROTOCOL` / `WEBHOOK_URL` | Public URLs — adapt when behind a reverse proxy |
| `GENERIC_TIMEZONE` | Timezone applied to scheduled workflows |

Full variable reference: <https://docs.n8n.io/hosting/configuration/environment-variables/>

## Persistence

Data is stored in two named Docker volumes:

- `n8n_storage` → workflows, encrypted credentials, n8n config (`/home/node/.n8n`)
- `db_storage` → PostgreSQL data

## Backup & Restore

Two scripts live under `scripts/`:

```bash
./scripts/backup.sh                       # writes .backup/<timestamp>/
./scripts/restore.sh .backup/<timestamp>  # restores (⚠ destructive, asks confirmation)
```

A backup contains a `pg_dump` (custom format, gzipped) of the Postgres database and a tarball of the `n8n_storage` volume. The `.backup/` folder is gitignored.

### Automatic backups

The `backup` service in `docker-compose.yml` is a cron sidecar that runs `scripts/backup.sh` on a schedule. Configure it via `BACKUP_CRON` in `.env`:

```bash
BACKUP_CRON=0 */6 * * *    # every 6 hours (default)
BACKUP_CRON=0 2 * * *      # daily at 02:00
BACKUP_CRON=                # empty → disable automatic backups
```

Retention policy (applied after each backup by `scripts/prune.sh`):

- **Today** — keep every backup.
- **Other days of the current ISO week** (Mon → Sun) — keep only the latest of each day.
- **Older weeks** — keep only the latest backup of each ISO week.

Logs: `docker compose logs -f backup`. Trigger a backup on demand: `docker compose exec backup run-backup`.

⚠ **`.env` is NOT backed up** by design. Keep `N8N_ENCRYPTION_KEY` and the Postgres passwords in a secret manager — without the same encryption key, restored credentials cannot be decrypted.

## Production

For a public deployment:

1. Put n8n behind an HTTPS reverse proxy (Caddy, Traefik, Nginx).
2. Update `N8N_PROTOCOL=https`, `N8N_HOST=your-domain`, `WEBHOOK_URL=https://your-domain/`.
3. Pin `N8N_VERSION` to a specific release.
4. Store secrets in a proper secret manager rather than in `.env`.
5. Set up a regular backup strategy for both volumes.

## License

[MIT](./LICENSE)

## References

- Official n8n documentation: <https://docs.n8n.io/>
- Docker installation: <https://docs.n8n.io/hosting/installation/docker/>
- Reference configurations: <https://github.com/n8n-io/n8n-hosting>
