---
name: status
description: Snapshot lecture pure de l'etat des apps sur le VPS. Pour une app : containers + healthcheck HTTPS + tag courant. Sans arg : liste toutes les apps. Verdict HEALTHY/DEGRADED/DOWN par app. Aucune ecriture. Triggers : "status deploy", "etat des apps", "qu'est-ce qui tourne sur le VPS", "ps prod", "/deploy-vps:status".
---

# status [app]

Snapshot lecture pure de l'etat d'une app (ou de toutes). Aucune ecriture, aucune modification.

## Workflow

1. Identifier les apps a check :
   - Si argument `app` fourni : juste cette app.
   - Sinon : `ls ${VPS_ORCHESTRATOR_PATH}/apps/` et boucler.

2. Pour chaque app :
   a. Lire `apps/<app>/deploy-state.yaml` (yq) : `tag`, `version`, `deployed_at`, `deployed_by`.
   b. SSH VPS : `cd /opt/<app>/deploy-vps && docker compose --env-file /opt/<app>/.env ps`.
   c. Pour chaque container : Service, Status, Image (avec tag), Health.
   d. Curl healthcheck : `https://<app>.${VPS_APPS_DOMAIN}/healthz` (timeout 5s, fallback `/`).

3. Formater en Markdown :

```markdown
## <app> — <tag> (deployed <deployed_at> by <deployed_by>)

| Service | Status | Image | Health |
|---|---|---|---|
| buck-app | Up 3h (healthy) | ghcr.io/erom/buck-app:v1.0.0 | OK |

Healthcheck https://<app>.${VPS_APPS_DOMAIN}/healthz -> 200
```

4. Verdict global par app :
   - Tous containers `Up` ET healthcheck 200 -> HEALTHY
   - >= 1 container restarting/exited OU healthcheck non-200 -> DEGRADED
   - Tous containers down OU healthcheck timeout -> DOWN

## Implementation

```bash
#!/usr/bin/env bash
set -euo pipefail

APP="${1:-}"
VPS_HOST="${VPS_HOST}"

cd ${VPS_ORCHESTRATOR_PATH}

if [ -n "$APP" ]; then
  apps="$APP"
else
  apps=$(ls -1 apps/ 2>/dev/null)
fi

for app in $apps; do
  state_file="apps/$app/deploy-state.yaml"
  [ -f "$state_file" ] || { echo "## $app -- (not initialized)"; continue; }

  tag=$(yq '.tag // "(never deployed)"' "$state_file")
  deployed_at=$(yq '.deployed_at // "n/a"' "$state_file")
  deployed_by=$(yq '.deployed_by // "n/a"' "$state_file")

  echo "## $app -- $tag (deployed $deployed_at by $deployed_by)"
  echo ""
  ssh "$VPS_HOST" \
    "cd /opt/$app/deploy-vps 2>/dev/null && docker compose --env-file /opt/$app/.env ps --format 'table {{.Service}}\t{{.Status}}\t{{.Image}}'" \
    2>&1 || echo "  SSH/compose error (app deployee ?)"
  echo ""

  health_url="https://${app}.${VPS_APPS_DOMAIN}/healthz"
  code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 5 "$health_url" || echo "000")
  if [ "$code" = "200" ]; then
    echo "Healthcheck $health_url -> 200 (HEALTHY)"
  elif [ "$code" = "000" ]; then
    echo "Healthcheck $health_url -> timeout (DOWN)"
  else
    echo "Healthcheck $health_url -> $code (DEGRADED)"
  fi
  echo "---"
done
```

## Restrictions

- Aucune ecriture. Pas de `docker compose stop/start/restart`, pas de modification de fichier, pas de `git commit`.
- Pas de decryption sops (donc pas d'acces aux secrets).
- Le SSH ne fait que des `docker compose ps` et `curl`.
- Si une app n'a pas d'endpoint `/healthz`, fallback sur `/` avec acceptation 200/301/302/401 comme "up".
