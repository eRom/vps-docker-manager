---
name: secret-rotate
description: Edit/rotate secrets sops dans vps-docker-manager-prod/secrets/<app>.enc.yaml. Input silencieux (read -s, jamais d'echo). Decrypt -> edit en clair temporaire (mktemp + shred trap) -> re-chiffre -> commit. Propose redeploy automatique apres rotation. Pour _common ou infra, edite le secrets.enc.yaml a la racine. Triggers : "rotate secrets <app>", "edit secrets", "changer la cle <X>", "secret rotation", "/deploy-vps:secret-rotate".
---

# secret-rotate [app]

Edit/rotate secrets sops d'une app. Input silencieux. Defaut `app = buck`.

## Args

- `app` (optionnel, defaut `buck`) : nom court de l'app, OU `_common` / `infra` pour les secrets root.

## Workflow

### Etape 1 — Resolution du fichier source

```bash
cd ${VPS_ORCHESTRATOR_PATH}

if [ "$APP" = "_common" ] || [ "$APP" = "infra" ]; then
  ENC_FILE="secrets.enc.yaml"
  CTX="infra (root secrets.enc.yaml)"
else
  ENC_FILE="secrets/${APP}.enc.yaml"
  CTX="app '${APP}'"
fi

[ -f "$ENC_FILE" ] || abort "$ENC_FILE introuvable"
command -v sops >/dev/null || abort "sops requis"
command -v yq   >/dev/null || abort "yq requis (mikefarah/yq)"
```

### Etape 2 — Decrypt vers fichier temp securise

```bash
CLEAR_FILE=$(mktemp -t rotate-XXXXXXXX.yaml)
trap 'shred -u "$CLEAR_FILE" 2>/dev/null || trash "$CLEAR_FILE"' EXIT

sops -d "$ENC_FILE" > "$CLEAR_FILE"
```

Le `trap EXIT` garantit le shred meme si le script crash.

### Etape 3 — Lister les cles disponibles

Top-level + nested 1 niveau :

```bash
{
  grep -E '^[A-Za-z_][A-Za-z0-9_]*:' "$CLEAR_FILE" | cut -d':' -f1
  awk '
    /^[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*$/ { parent = substr($0, 1, length($0)-1); next }
    /^  [A-Za-z_][A-Za-z0-9_]*:/ && parent != "" {
      gsub(/^  /, ""); gsub(/:.*/, "");
      print parent "." $0
    }
    /^[^ ]/ { parent = "" }
  ' "$CLEAR_FILE"
} | sort -u | nl -w3 -s') '
```

### Etape 4 — Demander cles + nouvelles valeurs

Pour chaque cle, prompt silencieux (`read -rs`). NE JAMAIS afficher la valeur saisie ni la logger.

```bash
for ((i=1; i<=N; i++)); do
  read -rp "[$i/$N] Cle (ex: OPENAI_API_KEY ou uptime_kuma.TELEGRAM_BOT_TOKEN): " KEY
  echo -n "[$i/$N] Nouvelle valeur (input cache) : "
  read -rs NEW_VAL
  echo ""
  [ -z "$NEW_VAL" ] && { echo "Valeur vide, skip"; continue; }

  NEW="$NEW_VAL" yq -i ".${KEY} = strenv(NEW)" "$CLEAR_FILE"
  unset NEW_VAL NEW
  echo "OK $KEY mise a jour (en clair temporaire)"
done
```

### Etape 5 — Re-chiffrer + shred

```bash
sops -e "$CLEAR_FILE" > "${ENC_FILE}.new"
mv "${ENC_FILE}.new" "$ENC_FILE"
shred -u "$CLEAR_FILE"
trap - EXIT
```

### Etape 6 — Commit + push

```bash
git add "$ENC_FILE"
git commit -m "chore(secrets): rotate ${#KEYS[@]} keys in ${ENC_FILE}

Keys rotated: ${KEYS[*]}"

read -rp "Push maintenant ? (y/N) " PUSH
[[ "$PUSH" =~ ^[Yy]$ ]] && git push origin main
```

### Etape 7 — Proposer redeploy

Si app != `_common`/`infra`, proposer :

```bash
read -rp "Trigger redeploy ${APP} maintenant ? (y/N) " REDEPLOY
if [[ "$REDEPLOY" =~ ^[Yy]$ ]]; then
  CURR_TAG=$(yq '.tag' "apps/${APP}/deploy-state.yaml")
  CURR_SHA=$(yq '.sha' "apps/${APP}/deploy-state.yaml")
  APP_REPO=$(yq '.app_repo' "apps/${APP}/deploy-state.yaml")
  gh workflow run deploy.yml --repo eRom/vps-docker-manager-prod \
    -f app="$APP" -f app_repo="$APP_REPO" \
    -f tag="$CURR_TAG" -f deploy_vps_ref="$CURR_SHA"
fi
```

Le redeploy est necessaire car le `.env` runtime sur le VPS est genere depuis le sops decrypte au moment du deploy.

## Restrictions

- INPUT SILENCIEUX OBLIGATOIRE (`read -rs`). Ne JAMAIS afficher une valeur saisie.
- Ne JAMAIS logger les valeurs (pas de `echo $NEW_VAL`, pas de `set -x`).
- `shred -u` apres usage du fichier en clair (defense en profondeur, pas de `rm`).
- `trap EXIT` pour shred meme en cas de crash.
- Le repo prod est PRIVE — le `.enc.yaml` chiffre est OK a committer.
- Si une cle leak en clair pendant la session (output console, history shell), avertir l'utilisateur de la rotater immediatement.

Reference d'implementation : `vps-docker-manager-prod/scripts/rotate-secrets.sh`.
