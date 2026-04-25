#!/usr/bin/env bash
set -euo pipefail
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly INFRA_DIR="$(dirname "${SCRIPT_DIR}")"
cd "${INFRA_DIR}"
echo "[stop] Arret docker compose..."
docker compose down
echo "[stop] OK."
