---
name: rollback
description: Rollback d'une app vers un tag precedent. Chemin A (par defaut) trigger workflow_dispatch deploy.yml avec confirmation explicite. Chemin B (parachute) execute /opt/_infra/scripts/rollback.sh en SSH si demande "use SSH" ou si GH Actions est down. Resolution SHA + verification image GHCR existe avant action. Triggers : "rollback <app>", "revenir a <tag>", "previous version <app>", "/deploy-vps:rollback".
---

# rollback <app> <tag>

Rollback d'une app vers un tag GHCR precedent. Action destructive (deploie une autre version).

## Args

- `app` (obligatoire) : nom court (`buck`, `n8n`, `trinity`).
- `tag` (obligatoire) : tag complet cible (ex: `buck-v1.0.0`).

## Chemin A — workflow_dispatch (par defaut, recommande)

### Etape 1 — Validation

```bash
cd ${VPS_ORCHESTRATOR_PATH}
[ -f "apps/$APP/deploy-state.yaml" ] || abort "App $APP non initialisee"
[ -f "secrets/$APP.enc.yaml" ] || abort "Secrets $APP absents"
```

### Etape 2 — Resolution SHA cible

```bash
APP_REPO=$(yq '.app_repo' apps/$APP/deploy-state.yaml)
SHA=$(gh release view "$TAG" --repo "$APP_REPO" --json targetCommitish --jq '.targetCommitish' 2>/dev/null) \
  || SHA=$(gh api "repos/$APP_REPO/git/refs/tags/$TAG" --jq '.object.sha')
```

Si echec : abort ("tag $TAG inexistant sur $APP_REPO").

### Etape 3 — Verifier image GHCR encore presente

```bash
VERSION="${TAG#*-}"
gh api "user/packages/container/${APP}-app/versions" \
  --jq ".[].metadata.container.tags[] | select(. == \"$VERSION\")" \
  | grep -q "$VERSION" \
  || abort "Image ghcr.io/erom/${APP}-app:${VERSION} purgee par retention"
```

(Verifier au moins l'image principale ; si elle est purgee, les autres aussi probablement.)

### Etape 4 — Recap + confirmation

```
=== ROLLBACK ===
App         : buck
Tag courant : buck-v1.0.1 (deployed 2026-04-26T10:00Z)
Tag cible   : buck-v1.0.0
SHA cible   : 5f3c8a9
Repo app    : eRom/buck-writer-app

Confirmer le rollback ? (y/N)
```

Attendre `y` explicite. Toute autre reponse = abort. NE JAMAIS lancer le rollback sans confirmation.

### Etape 5 — Trigger workflow

```bash
gh workflow run deploy.yml --repo eRom/vps-docker-manager-prod \
  -f app="$APP" \
  -f app_repo="$APP_REPO" \
  -f tag="$TAG" \
  -f deploy_vps_ref="$SHA"
```

### Etape 6 — Watch + verification

```bash
sleep 3
RUN_ID=$(gh run list --repo eRom/vps-docker-manager-prod --workflow deploy.yml --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RUN_ID" --repo eRom/vps-docker-manager-prod --exit-status

curl -sS -o /dev/null -w "%{http_code}\n" --max-time 10 \
  "https://${APP}.${VPS_APPS_DOMAIN}/healthz"
```

## Chemin B — SSH parachute (fallback)

Utiliser uniquement si :
- L'utilisateur dit explicitement "use SSH" / "parachute".
- `gh workflow run` echoue (GitHub Actions down).
- Urgence prod et le pipeline GA traine.

```bash
ssh ${VPS_HOST} "/opt/_infra/scripts/rollback.sh $APP $TAG"
```

Apres rollback parachute, RAPPELER a l'utilisateur :

> Rollback fait via SSH parachute. `apps/$APP/deploy-state.yaml` n'a PAS ete commit cote vps-docker-manager-prod.
>
> Pense a synchroniser :
> ```bash
> cd ${VPS_ORCHESTRATOR_PATH}
> python3 scripts/update-state.py --app $APP --tag $TAG --ref $SHA --actor manual-rollback
> git add apps/$APP/ && git commit -m "rollback: $APP $TAG (manual SSH)" && git push
> ```

## Restrictions

- Confirmation obligatoire avant action.
- Verifier image GHCR existe AVANT trigger workflow (eviter un deploy qui pull une image absente -> container restart loop).
- Pas de re-build : on utilise les images deja sur GHCR.
- Pas de tag git : rollback != re-tag. Le tag cible existe deja.
