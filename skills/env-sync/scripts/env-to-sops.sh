#!/usr/bin/env bash
# env-to-sops.sh — synchronise un .env local vers <orchestrator>/secrets/<app>.enc.yaml
#
# Usage : env-to-sops.sh <app> <path-to-.env>
#
# Garanties :
# - aucun fichier en clair ecrit sur disk (pipe stdin -> sops)
# - aucune valeur affichee en stdout, seulement les noms de keys
# - ecriture atomique du .enc.yaml (mv depuis .tmp)

set -euo pipefail

abort() { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Args ---
[ $# -ge 2 ] || abort "Usage : $0 <app> <path-to-.env>"

APP=$1
ENV_FILE=$2

# --- Pre-flight ---
: "${VPS_ORCHESTRATOR_PATH:?Set VPS_ORCHESTRATOR_PATH in ~/.zshenv}"

ENC_FILE="$VPS_ORCHESTRATOR_PATH/secrets/$APP.enc.yaml"
TMP_FILE="$ENC_FILE.tmp"

[ -f "$ENV_FILE" ] || abort "Fichier $ENV_FILE introuvable."
[ -f "$ENC_FILE" ] || abort "$ENC_FILE inexistant — bootstrap l'app d'abord."
command -v sops >/dev/null || abort "sops absent du PATH."

# --- Sync : .env -> YAML stream -> sops -> .enc.yaml.tmp ---
# awk strip commentaires + lignes vides, escape les valeurs YAML simples (single-quote).
# Pour des valeurs multiline ou avec quotes complexes, edite a la main avec : sops "$ENC_FILE"
awk -F= '
  !/^[[:space:]]*(#|$)/ {
    key = $1
    # reconstruire la valeur en gardant les "=" eventuels
    sub(/^[^=]*=/, "", $0)
    val = $0
    # strip surrounding quotes simples ou doubles si presents
    gsub(/^["'"'"']|["'"'"']$/, "", val)
    # escape single-quotes pour YAML single-quoted string
    gsub(/'"'"'/, "'"'"''"'"'", val)
    printf "%s: '"'"'%s'"'"'\n", key, val
  }
' "$ENV_FILE" \
  | sops --input-type yaml --output-type yaml -e /dev/stdin \
  > "$TMP_FILE"

# --- Sanity : le fichier chiffre doit contenir le marker sops ---
if ! grep -q "sops:" "$TMP_FILE"; then
  rm -f "$TMP_FILE"
  abort "Resultat sops invalide (pas de marker sops:). Aborted."
fi

# --- Atomic swap ---
mv "$TMP_FILE" "$ENC_FILE"

# --- Diff resume : noms de keys uniquement ---
printf '\033[32mOK\033[0m %s mis a jour. Keys synchronisees :\n' "$ENC_FILE"
awk -F= '!/^[[:space:]]*(#|$)/ { print "  - "$1 }' "$ENV_FILE"

cat <<EOF

Next :
  cd \$VPS_ORCHESTRATOR_PATH
  git diff --stat secrets/$APP.enc.yaml
  git add secrets/$APP.enc.yaml && git commit -m "chore(secrets/$APP): sync from .env"
EOF
