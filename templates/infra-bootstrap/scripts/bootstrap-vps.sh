#!/usr/bin/env bash
# bootstrap-vps.sh — Idempotent. Execute sur le VPS via SSH.
# Premier run : installe sops/age si manquants, cree la cle age VPS, s'arrete.
# Runs suivants : verifie l'etat, cree le reseau et acme.json si manquants.

set -euo pipefail

readonly SOPS_VERSION="v3.12.2"
readonly INFRA_DIR="/opt/_infra"
readonly DATA_DIR="/opt/_data"
readonly BACKUP_DIR="/opt/_backups"
readonly AGE_KEY_PATH="/root/.config/sops/age/keys.txt"

log() { echo "[bootstrap] $*"; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Ce script doit etre execute en root." >&2
    exit 1
  fi
}

install_prereqs() {
  log "Verification prerequis systeme..."
  command -v docker >/dev/null || {
    log "Installation docker..."
    apt-get update -qq
    apt-get install -y -qq docker.io docker-compose-plugin
  }
  command -v age >/dev/null || {
    log "Installation age..."
    apt-get install -y -qq age
  }
  if ! command -v sops >/dev/null; then
    log "Installation sops ${SOPS_VERSION}..."
    curl -sSL "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.amd64" \
      -o /usr/local/bin/sops
    chmod +x /usr/local/bin/sops
  fi
}

create_dirs() {
  log "Creation arborescence /opt/..."
  mkdir -p "${INFRA_DIR}" "${DATA_DIR}" "${BACKUP_DIR}"
}

generate_age_key_if_missing() {
  mkdir -p "$(dirname "${AGE_KEY_PATH}")"
  if [ ! -f "${AGE_KEY_PATH}" ]; then
    log "Generation cle age VPS..."
    age-keygen -o "${AGE_KEY_PATH}"
    chmod 600 "${AGE_KEY_PATH}"
    echo
    echo "================================================================"
    echo "CLE PUBLIQUE VPS A AJOUTER DANS .sops.yaml LOCAL :"
    grep '# public key' "${AGE_KEY_PATH}" | sed 's/# public key: //'
    echo "================================================================"
    echo
    echo "Etapes a executer en local :"
    echo "  1. Remplacer __AGE_PUBKEY_VPS__ dans .sops.yaml par la cle ci-dessus"
    echo "  2. sops updatekeys secrets.enc.yaml"
    echo "  3. git add .sops.yaml secrets.enc.yaml && git commit && git push"
    echo "  4. Sur le VPS : git pull dans ${INFRA_DIR} puis re-executer ce script"
    exit 0
  fi
  log "Cle age VPS deja presente."
}

create_network() {
  if ! docker network inspect traefik-public >/dev/null 2>&1; then
    log "Creation reseau traefik-public..."
    docker network create traefik-public
  else
    log "Reseau traefik-public deja present."
  fi
}

prepare_acme_storage() {
  local acme_file="${INFRA_DIR}/data/acme.json"
  mkdir -p "${INFRA_DIR}/data"
  if [ ! -f "${acme_file}" ]; then
    touch "${acme_file}"
  fi
  chmod 600 "${acme_file}"
  log "acme.json pret (${acme_file}, chmod 600)."
}

main() {
  require_root
  install_prereqs
  create_dirs
  generate_age_key_if_missing
  create_network
  prepare_acme_storage
  log "Bootstrap termine. Lancer ./scripts/start.sh pour demarrer Traefik."
}

main "$@"
