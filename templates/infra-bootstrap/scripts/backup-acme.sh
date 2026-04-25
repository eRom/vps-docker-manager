#!/usr/bin/env bash
# backup-acme.sh — Snapshot horodate de acme.json. A executer en cron daily.

set -euo pipefail

readonly INFRA_DIR="/opt/_infra"
readonly BACKUP_DIR="/opt/_backups/acme"
readonly RETENTION_DAYS=30

mkdir -p "${BACKUP_DIR}"

if [ ! -f "${INFRA_DIR}/data/acme.json" ]; then
  echo "[backup-acme] acme.json introuvable, abort." >&2
  exit 1
fi

ts="$(date -u +%Y%m%d-%H%M%S)"
dest="${BACKUP_DIR}/acme-${ts}.json"
cp "${INFRA_DIR}/data/acme.json" "${dest}"
chmod 600 "${dest}"
echo "[backup-acme] Backup : ${dest}"

# Retention : supprime les backups plus vieux que RETENTION_DAYS jours
find "${BACKUP_DIR}" -name 'acme-*.json' -mtime +${RETENTION_DAYS} -delete
echo "[backup-acme] Retention appliquee (>${RETENTION_DAYS}j supprimes)."
