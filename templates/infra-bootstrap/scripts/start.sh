#!/usr/bin/env bash
# start.sh — Decrypte les secrets, genere le htpasswd dashboard, demarre Traefik+Uptime Kuma.

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly INFRA_DIR="$(dirname "${SCRIPT_DIR}")"
readonly SECRETS_FILE="${INFRA_DIR}/secrets.enc.yaml"
readonly HTPASSWD_FILE="${INFRA_DIR}/traefik/dynamic/.htpasswd-dashboard"

log() { echo "[start] $*"; }

cd "${INFRA_DIR}"

if [ ! -f "${SECRETS_FILE}" ]; then
  echo "Erreur : ${SECRETS_FILE} introuvable." >&2
  exit 1
fi

log "Dechiffrement des secrets..."
export CF_DNS_API_TOKEN="$(sops -d --extract '["cloudflare"]["CF_DNS_API_TOKEN"]' "${SECRETS_FILE}")"

log "Generation .htpasswd-dashboard..."
DASHBOARD_AUTH="$(sops -d --extract '["traefik"]["DASHBOARD_BASIC_AUTH"]' "${SECRETS_FILE}")"
# Le format stocke est "user:$2y$..." — on l'ecrit tel quel (htpasswd-style),
# en re-doublant les $ supprimes par sops si besoin (ici on prend la valeur brute).
echo "${DASHBOARD_AUTH}" > "${HTPASSWD_FILE}"
chmod 600 "${HTPASSWD_FILE}"

log "Demarrage docker compose..."
docker compose up -d

log "Attente 5s puis affichage des logs Traefik..."
sleep 5
docker compose logs --tail=30 traefik

log "Stack demarree. Verifications :"
echo "  - Dashboard : https://traefik.apps.romain-ecarnot.com"
echo "  - Status    : https://status.apps.romain-ecarnot.com"
echo "  - Logs live : docker compose logs -f traefik"
