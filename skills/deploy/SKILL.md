---
name: deploy
description: Deploy une app via le pattern tag-driven : git tag <app>-vX.Y.Z + push, watch GitHub Actions release.yml puis deploy.yml dans vps-docker-manager-prod. Resolution auto du SHA, suivi pipeline GHCR + scp + docker compose pull/up. Triggers : "deploy <app>", "release <app>", "tag <app>", "push <app> en prod", "/deploy-vps:deploy".
---

# deploy <app> <version>

Release une app via le pattern tag-driven. Workflow standard.

## Args

- `app` (obligatoire) : nom court (`buck`, `n8n`, `trinity`).
- `version` (obligatoire) : version semver (`v1.0.0`, `v1.2.3-rc.1`).

Tag complet construit : `<app>-<version>` (ex: `buck-v1.0.0`, `trinity-v1.0.0-rc.3`).

## Workflow

### Etape 1 — Pre-flight checks

1. Working directory du repo app propre (`git status` clean).
2. Branche `main` a jour (`git pull --ff-only origin main`).
3. Tag pas deja existant : `git tag -l "$APP-$VERSION"` doit etre vide.
4. (Optionnel mais recommande) `dns` skill : verifier que le domaine resout vers le VPS.

Si une etape echoue, abort avec message clair.

### Etape 2 — Creer + pousser le tag

```bash
cd <app-repo>
git tag "${APP}-${VERSION}"
git push origin "${APP}-${VERSION}"
```

### Etape 3 — Watch release.yml (cote repo app)

Le workflow `release.yml` du repo app est trigger sur `push` de tag matching `<app>-v*`. Il :

1. Build l'image GHCR (matrix de services si plusieurs).
2. Push vers `ghcr.io/erom/<app>-<service>:<version>`.
3. Dispatch un `repository_dispatch` vers `eRom/vps-docker-manager-prod` avec `app`, `tag`, `sha`.

```bash
sleep 3
RUN_ID=$(gh run list --repo "$APP_REPO" --workflow release.yml --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RUN_ID" --repo "$APP_REPO" --exit-status
```

### Etape 4 — Watch deploy.yml (cote vps-docker-manager-prod)

Une fois release.yml OK, le dispatch trigger `deploy.yml` cote prod :

1. Decrypt sops `secrets/<app>.enc.yaml`.
2. Genere `.env` runtime.
3. scp `deploy-vps/` + `.env` vers `/opt/<app>/` sur VPS.
4. SSH `docker compose pull && docker compose up -d --remove-orphans`.
5. Healthcheck.
6. Commit `apps/<app>/deploy-state.yaml` mis a jour.

```bash
sleep 5
RUN_ID=$(gh run list --repo eRom/vps-docker-manager-prod --workflow deploy.yml --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RUN_ID" --repo eRom/vps-docker-manager-prod --exit-status
```

### Etape 5 — Verification post-deploy

```bash
curl -sS -o /dev/null -w "%{http_code}\n" --max-time 10 \
  "https://${APP}.${VPS_APPS_DOMAIN}/healthz"
```

Si != 200, suggerer la skill `deploy-doctor` pour diagnostic.

## Restrictions

- Le tag git doit suivre exactement `<app>-vX.Y.Z[-rc.N]`. Sinon release.yml ne match pas.
- Ne PAS amender un tag deja pousse. Faire un nouveau tag (`-rc.N+1` ou bump patch).
- Si release.yml echoue, le tag reste — le supprimer manuellement avant retry : `git push --delete origin <tag> && git tag -d <tag>`.
- Le commit auto de `deploy-state.yaml` cote prod implique que `INFRA_DISPATCH_PAT` doit avoir Contents=Write.
