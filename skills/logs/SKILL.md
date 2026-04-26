---
name: logs
description: Tail des logs Docker d'une app deployee sur le VPS, optionnellement filtres par service et fenetre temporelle. Lecture pure, pas de --follow. Triggers : "logs <app>", "voir logs <app>", "qu'est-ce que dit <app>", "tail logs prod", "/deploy-vps:logs".
---

# logs <app> [--since 10m] [--service <name>] [--tail N]

Tail les logs Docker d'une app deployee. Lecture pure.

## Args

- `app` (obligatoire) : nom court (`buck`, `n8n`, `trinity`).
- `--since <duration>` (optionnel) : fenetre Docker (`10m`, `1h`, `24h`).
- `--service <name>` (optionnel) : limite a un service du compose (`buck-app`, `bible-mcp`, etc.).
- `--tail N` (optionnel, defaut 200) : nombre de lignes max.

## Workflow

1. Parser args : positional `app`, flags `--since`/`--service`/`--tail`.
2. SSH VPS et exec `docker compose logs` avec les bons flags.
3. Stream la sortie (pas de `--follow`).

## Implementation

```bash
#!/usr/bin/env bash
set -euo pipefail

APP=""
SINCE=""
SERVICE=""
TAIL="200"

while [[ $# -gt 0 ]]; do
  case $1 in
    --since)   SINCE="$2"; shift 2 ;;
    --service) SERVICE="$2"; shift 2 ;;
    --tail)    TAIL="$2"; shift 2 ;;
    *) APP="$1"; shift ;;
  esac
done

[ -n "$APP" ] || { echo "Usage: logs <app> [--since 10m] [--service <name>] [--tail N]"; exit 1; }

VPS_HOST="${VPS_HOST}"

CMD="cd /opt/$APP/deploy-vps && docker compose --env-file /opt/$APP/.env logs --tail=$TAIL"
[ -n "$SINCE" ]   && CMD="$CMD --since $SINCE"
[ -n "$SERVICE" ] && CMD="$CMD $SERVICE"

ssh "$VPS_HOST" "$CMD"
```

## Restrictions

- Lecture pure. Pas de `--follow` (boucle infinie).
- Limite a 200 lignes par defaut. Pour plus de contexte temporel, utiliser `--since 24h`.
- Si l'utilisateur cherche un pattern d'erreur specifique, suggerer un grep cote local apres recuperation : `... | grep -iE 'error|warn|panic'`.
