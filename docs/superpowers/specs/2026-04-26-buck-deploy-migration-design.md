# Spec — Migration deploy prod Buck (et pattern multi-apps)

**Date** : 2026-04-26
**Auteur** : Romain + Claude (brainstorming)
**Statut** : à valider
**Sous-projet** : `migration-trinity-buck` (programme global), pilote = Buck Writer

---

## 1. Contexte et objectif

### 1.1 État de départ

L'infra `infra-bootstrap` v0.1.0 est livrée sur le VPS Hostinger (`72.62.239.98`) :
Traefik 3.6.14 + ACME LE prod (DNS challenge Cloudflare), wildcard
`*.apps.romain-ecarnot.com` valide, Uptime Kuma + alertes Telegram, sops/age
secrets, réseau Docker partagé `traefik-public`. Trinity et Buck legacy ont été
wipés du VPS pendant T18 ; seuls Traefik et Uptime Kuma tournent.

L'ancien deploy Buck était un script `vps/deploy.sh` de 200 lignes qui :
- faisait `git fetch + reset --hard` côté VPS, puis `docker compose build`
  (5 min de CPU à 100 %, dont ~3 GB pour `writing-tools-mcp`) ;
- scp deux `.env` plaintext (`.env.production` + `.env.trinity`) ;
- modifiait `Caddyfile` et `.env` du repo Trinity, puis force-recreate Caddy
  Trinity (couplage fort Buck ↔ Trinity, impossible de deployer Buck si
  Trinity est down) ;
- ne tenait aucun journal, aucun rollback, aucun backup data.

### 1.2 Objectif de cette spec

Définir un **pattern réutilisable de déploiement VPS multi-apps** :

- Pilote : **Buck Writer** (premier onboardé, valide le pattern).
- Apps suivantes via le même pattern : `n8n`, `trinity`, plus dans le futur.
- Granularité : releaser une app ne touche jamais les autres.
- Trigger : uniquement sur tag, jamais sur push.
- Build : pré-builds GHCR via GitHub Actions, pas de build runtime sur le VPS.
- Secrets : sops dans le repo infra prod séparé (`vps-docker-manager-prod`).
- Tooling Claude : skills `/deploy:*` + sous-agent diagnostique.

### 1.3 Hors scope (traités ailleurs)

- **`deploy-local`** : spec séparé, à brainstormer après stabilisation prod.
- **Onboarding n8n et trinity** : exécution du pattern, pas design. Notes
  Gerber pour leurs spécificités.
- **Phase B backup remote** : sync vers stockage externe (Backblaze B2 vs
  Hetzner Storage Box), choix du remote différé.
- **Arrêt définitif du repo Trinity** : tant que `/deploy:bootstrap trinity`
  n'est pas exécuté, Trinity ne tourne plus sur le VPS. Le repo legacy reste
  archivé tel quel.

---

## 2. Architecture macro

### 2.1 Trois acteurs

```
┌─────────────────────────┐         ┌──────────────────────────────┐
│  buck-writer-app (pub)  │         │  vps-docker-manager-prod      │
│                         │         │  (privé — journal du VPS)     │
│  src/                   │         │                               │
│  packages/              │         │  apps/                        │
│  deploy-vps/            │ tag     │    buck/deploy-state.yaml     │
│    ├ compose.yml        │ buck-v* │    gerber/deploy-state.yaml   │
│    ├ labels Traefik     │ ──────► │    trinity/deploy-state.yaml  │
│    └ Dockerfile.*       │repo_dis │  secrets/                     │
│  .github/workflows/     │ patch   │    buck.enc.yaml (sops)       │
│    release.yml ─────────┼─builds──┼─► ghcr.io/erom/buck-app:v1.2.3│
└─────────────────────────┘         │  scripts/                     │
                                    │    deploy.sh, rollback.sh     │
                                    │    backup-<app>.sh            │
                                    │  .github/workflows/           │
                                    │    deploy.yml (réagit)        │
                                    └──────────────┬────────────────┘
                                                   │ SSH + sops decrypt
                                                   ▼
                                    ┌──────────────────────────────┐
                                    │  VPS Hostinger 72.62.239.98  │
                                    │                               │
                                    │  /opt/_infra/   (clone prod)  │
                                    │  /opt/buck/     (compose run) │
                                    │  /opt/gerber/                 │
                                    │  Traefik (traefik-public net) │
                                    └──────────────────────────────┘
```

### 2.2 Responsabilités

**Repo app** (`buck-writer-app`, futurs `n8n-stack`, `trinity-stack`...) :
- Code applicatif.
- Dossier `deploy-vps/` à la racine : `compose.yml`, `Dockerfile.*`,
  scripts d'init container.
- Workflow GA `release.yml` : sur tag `<app>-v*`, build et push toutes les
  images sur GHCR, puis `repository_dispatch` vers le repo infra prod.
- Secrets GA : `INFRA_DISPATCH_PAT` (PAT scoped : `repo` write sur
  `vps-docker-manager-prod` uniquement).

**Repo infra prod** (`vps-docker-manager-prod`, privé) :
- Journal git de l'état du VPS (`apps/<app>/deploy-state.yaml`).
- Secrets sops (`secrets/<app>.enc.yaml`).
- Scripts ops (`scripts/deploy.sh`, `rollback.sh`, `backup-<app>.sh`).
- Workflow GA `deploy.yml` : réagit aux `repository_dispatch` ou aux
  `workflow_dispatch` manuels (rollback, redeploy forcé).
- Détient le **seul** secret SSH VPS (`VPS_SSH_KEY`), la clé age
  (`SOPS_AGE_KEY`), et les coordonnées VPS (`VPS_HOST`).
- Skills Claude (`.claude/skills/deploy/*.md`) et sous-agent
  (`.claude/agents/deploy-doctor.md`).

**VPS** :
- Traefik + réseau `traefik-public` (déjà en place via infra-bootstrap).
- Un dossier `/opt/<app>/` par app :
  - `/opt/<app>/deploy-vps/` : compose pulled à chaque deploy depuis le repo app.
  - `/opt/<app>/.env` : `.env` déchiffré par le runner GA, scp lors du deploy.
  - `/opt/<app>/data/` : volumes persistants.
- `/opt/_infra/` : clone du repo infra prod, contient les scripts ops
  invoqués par cron (backup) ou par le mode rollback parachute.

### 2.3 Flux d'un release Buck

1. `git tag buck-v1.2.3 && git push --tags` sur `buck-writer-app`.
2. GA `release.yml` build les images → push
   `ghcr.io/erom/buck-{app,bible-mcp,writing-tools-mcp,bible-ui,markitdown-worker}:v1.2.3`.
3. GA dispatch `{app: "buck", tag: "buck-v1.2.3", sha: "<sha>", deploy_vps_ref: "<sha>"}`
   vers `vps-docker-manager-prod`.
4. GA `deploy.yml` reçoit l'event :
   - Commit `apps/buck/deploy-state.yaml` (tag courant + sha) sur main.
   - SSH VPS, scp `deploy-vps/` du tag Buck dans `/opt/buck/deploy-vps/`.
   - Sops decrypt `secrets/buck.enc.yaml` → scp `/opt/buck/.env`.
   - `docker compose pull && up -d`.
   - Healthcheck `https://buck.apps.romain-ecarnot.com/api/health`.
   - Notif Telegram.

---

## 3. Anatomie d'une app `deploy-vps/`

### 3.1 Convention canonique

```
<app-repo>/
├── src/                       (code)
├── packages/                  (code)
├── deploy-vps/
│   ├── compose.yml            ← image refs GHCR + labels Traefik
│   ├── Dockerfile.app         ← multi-stage prod
│   ├── Dockerfile.bible-mcp   ← (autres images si app multi-services)
│   ├── Dockerfile.*
│   ├── healthcheck.sh         (optionnel — script multi-endpoint)
│   └── README.md              ← doc deploy spécifique app
└── .github/workflows/
    └── release.yml            ← tag → build/push GHCR → dispatch
```

### 3.2 `compose.yml` — exemple Buck

```yaml
services:
  buck-app:
    image: ghcr.io/erom/buck-app:${TAG:-latest}
    container_name: buck-app
    restart: unless-stopped
    env_file: /opt/buck/.env
    volumes:
      - /opt/buck/data/db:/app/data
      - /opt/buck/data/workspace:/app/workspace
    networks: [traefik-public, internal]
    labels:
      - traefik.enable=true
      - traefik.docker.network=traefik-public
      - traefik.http.routers.buck.rule=Host(`buck.apps.romain-ecarnot.com`)
      - traefik.http.routers.buck.entrypoints=websecure
      - traefik.http.routers.buck.tls.certresolver=cloudflare
      - traefik.http.services.buck.loadbalancer.server.port=3000

  bible-ui:
    image: ghcr.io/erom/buck-bible-ui:${TAG:-latest}
    networks: [traefik-public, internal]
    labels:
      - traefik.enable=true
      - traefik.http.middlewares.buck-sso.forwardauth.address=http://buck-app:3000/api/auth/verify-session
      - traefik.http.middlewares.buck-sso.forwardauth.authResponseHeaders=X-User-Id
      - traefik.http.routers.bible-ui.rule=Host(`bible.buck.apps.romain-ecarnot.com`)
      - traefik.http.routers.bible-ui.middlewares=buck-sso@docker
      - traefik.http.routers.bible-ui.entrypoints=websecure
      - traefik.http.routers.bible-ui.tls.certresolver=cloudflare
      - traefik.http.services.bible-ui.loadbalancer.server.port=8080

  bible-mcp:
    image: ghcr.io/erom/buck-bible-mcp:${TAG:-latest}
    networks: [traefik-public, internal]
    labels:
      - traefik.enable=true
      - traefik.http.routers.bible-mcp.rule=Host(`bible-mcp.buck.apps.romain-ecarnot.com`)
      - traefik.http.routers.bible-mcp.middlewares=bible-mcp-bearer@file
      - traefik.http.routers.bible-mcp.entrypoints=websecure
      - traefik.http.routers.bible-mcp.tls.certresolver=cloudflare
      - traefik.http.services.bible-mcp.loadbalancer.server.port=7801

  writing-tools-mcp:
    image: ghcr.io/erom/buck-writing-tools-mcp:${TAG:-latest}
    networks: [traefik-public, internal]
    labels:
      - traefik.enable=true
      - traefik.http.routers.writing-mcp.rule=Host(`writing-mcp.buck.apps.romain-ecarnot.com`)
      - traefik.http.routers.writing-mcp.middlewares=writing-mcp-bearer@file
      - traefik.http.routers.writing-mcp.entrypoints=websecure
      - traefik.http.routers.writing-mcp.tls.certresolver=cloudflare
      - traefik.http.services.writing-mcp.loadbalancer.server.port=7802

  markitdown-worker:
    image: ghcr.io/erom/buck-markitdown-worker:${TAG:-latest}
    networks: [internal]
    env_file: /opt/buck/.env

networks:
  traefik-public:
    external: true
  internal:
    driver: bridge
```

### 3.3 Trois conventions clés

1. **`image:` toujours GHCR taggée** — jamais de `build:` au runtime VPS. Le
   tag est injecté via `${TAG}` dans le `.env` par le script de deploy.
2. **Routing 100 % en labels Traefik** — un container, sa conf de routing
   voyage avec lui.
3. **Middlewares qui touchent un secret** (Bearer auth MCP) → définis dans la
   conf statique Traefik côté `vps-docker-manager-prod/infra/dynamic/buck.yaml`,
   **pas en label** (sinon le secret apparaît dans `docker inspect`). Les
   labels du compose **référencent** ces middlewares (`@file`).

### 3.4 Middleware Bearer (côté infra prod)

`vps-docker-manager-prod/infra/dynamic/buck.yaml` (mounté dans Traefik via le
compose Traefik existant) :

```yaml
http:
  middlewares:
    bible-mcp-bearer:
      headers:
        customRequestHeaders:
          X-Required-Auth: "Bearer __MCP_SHARED_SECRET__"
    writing-mcp-bearer:
      headers:
        customRequestHeaders:
          X-Required-Auth: "Bearer __MCP_SHARED_SECRET__"
```

Le placeholder `__MCP_SHARED_SECRET__` est substitué par le script deploy au
moment de pousser le fichier sur le VPS (sed avec la valeur déchiffrée du
sops). Alternative envisagée : `traefik.http.middlewares.X.plugin.checkheaders`
avec un plugin Traefik, mais ça ajoute une dépendance plugin, on garde simple.

---

## 4. Pipeline release-to-prod

### 4.1 Workflow A — `buck-writer-app/.github/workflows/release.yml`

```yaml
name: release
on:
  push:
    tags: ['buck-v*']

jobs:
  build-push:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    strategy:
      matrix:
        image:
          - { name: buck-app,                dockerfile: deploy-vps/Dockerfile.app }
          - { name: buck-bible-mcp,          dockerfile: deploy-vps/Dockerfile.bible-mcp }
          - { name: buck-bible-ui,           dockerfile: deploy-vps/Dockerfile.bible-ui }
          - { name: buck-writing-tools-mcp,  dockerfile: deploy-vps/Dockerfile.writing-tools-mcp }
          - { name: buck-markitdown-worker,  dockerfile: services/markitdown-worker/Dockerfile }
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Extract version from tag
        id: ver
        run: echo "version=${GITHUB_REF_NAME#*-}" >> $GITHUB_OUTPUT
        # ↑ buck-v1.2.3 → v1.2.3
      - uses: docker/build-push-action@v5
        with:
          context: .
          file: ${{ matrix.image.dockerfile }}
          push: true
          tags: |
            ghcr.io/erom/${{ matrix.image.name }}:${{ steps.ver.outputs.version }}
            ghcr.io/erom/${{ matrix.image.name }}:latest
          cache-from: type=gha,scope=${{ matrix.image.name }}
          cache-to:   type=gha,scope=${{ matrix.image.name }},mode=max

  dispatch:
    needs: build-push
    runs-on: ubuntu-latest
    steps:
      - name: Trigger deploy on infra repo
        uses: peter-evans/repository-dispatch@v3
        with:
          token: ${{ secrets.INFRA_DISPATCH_PAT }}
          repository: eRom/vps-docker-manager-prod
          event-type: app-release
          client-payload: |
            {
              "app": "buck",
              "app_repo": "${{ github.repository }}",
              "tag": "${{ github.ref_name }}",
              "sha": "${{ github.sha }}",
              "deploy_vps_ref": "${{ github.sha }}"
            }
```

### 4.2 Workflow B — `vps-docker-manager-prod/.github/workflows/deploy.yml`

```yaml
name: deploy
on:
  repository_dispatch:
    types: [app-release]
  workflow_dispatch:
    inputs:
      app:            { required: true,  type: string }
      app_repo:       { required: true,  type: string,  description: "Ex: eRom/buck-writer-app" }
      tag:            { required: true,  type: string,  description: "Ex: buck-v1.2.3" }
      deploy_vps_ref: { required: true,  type: string,  description: "SHA du repo app" }

concurrency:
  group: deploy-${{ github.event.client_payload.app || inputs.app }}
  cancel-in-progress: false

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Resolve inputs
        id: vars
        run: |
          APP="${{ github.event.client_payload.app || inputs.app }}"
          APP_REPO="${{ github.event.client_payload.app_repo || inputs.app_repo }}"
          TAG="${{ github.event.client_payload.tag || inputs.tag }}"
          REF="${{ github.event.client_payload.deploy_vps_ref || inputs.deploy_vps_ref }}"
          echo "app=$APP" >> $GITHUB_OUTPUT
          echo "app_repo=$APP_REPO" >> $GITHUB_OUTPUT
          echo "tag=$TAG" >> $GITHUB_OUTPUT
          echo "ref=$REF" >> $GITHUB_OUTPUT

      - uses: actions/checkout@v4

      - name: Update deploy-state.yaml + commit
        run: |
          python3 scripts/update-state.py \
            --app "${{ steps.vars.outputs.app }}" \
            --tag "${{ steps.vars.outputs.tag }}" \
            --ref "${{ steps.vars.outputs.ref }}"
          git config user.name "deploy-bot"
          git config user.email "deploy-bot@romain-ecarnot.com"
          git add apps/${{ steps.vars.outputs.app }}/deploy-state.yaml
          git commit -m "deploy: ${{ steps.vars.outputs.app }} ${{ steps.vars.outputs.tag }}"
          git push

      - name: Setup SSH + age
        run: |
          mkdir -p ~/.ssh ~/.config/sops/age
          echo "${{ secrets.VPS_SSH_KEY }}" > ~/.ssh/id_deploy && chmod 600 ~/.ssh/id_deploy
          echo "${{ secrets.SOPS_AGE_KEY }}" > ~/.config/sops/age/keys.txt
          ssh-keyscan -H ${{ secrets.VPS_HOST }} >> ~/.ssh/known_hosts

      - name: Run deploy.sh
        env:
          APP: ${{ steps.vars.outputs.app }}
          APP_REPO: ${{ steps.vars.outputs.app_repo }}
          TAG: ${{ steps.vars.outputs.tag }}
          DEPLOY_VPS_REF: ${{ steps.vars.outputs.ref }}
          VPS_HOST: ${{ secrets.VPS_HOST }}
          GH_TOKEN: ${{ secrets.INFRA_READ_PAT }}
        run: ./scripts/deploy.sh
```

### 4.3 `scripts/deploy.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

# Convention : TAG = "buck-v1.2.3", VERSION = "v1.2.3"
VERSION="${TAG#*-}"

# 1. Decrypt secrets pour cette app → fichier .env temporaire
sops -d secrets/${APP}.enc.yaml | yq -o=shell > /tmp/${APP}.env
echo "TAG=${VERSION}" >> /tmp/${APP}.env

# 2. Récupère le tarball deploy-vps/ depuis le repo app à la SHA exacte
gh api repos/${APP_REPO}/tarball/${DEPLOY_VPS_REF} > /tmp/app.tar.gz
mkdir /tmp/extract && tar xzf /tmp/app.tar.gz -C /tmp/extract --strip-components=1
DEPLOY_DIR=/tmp/extract/deploy-vps

# 3. Push sur VPS
ssh -i ~/.ssh/id_deploy root@${VPS_HOST} "mkdir -p /opt/${APP}/{data,deploy-vps}"
scp -i ~/.ssh/id_deploy -r ${DEPLOY_DIR}/* root@${VPS_HOST}:/opt/${APP}/deploy-vps/
scp -i ~/.ssh/id_deploy /tmp/${APP}.env root@${VPS_HOST}:/opt/${APP}/.env

# 4. Pull + up
ssh -i ~/.ssh/id_deploy root@${VPS_HOST} bash <<EOF
  set -euo pipefail
  cd /opt/${APP}/deploy-vps
  docker compose pull
  docker compose up -d --remove-orphans
  sleep 10
  docker compose ps
EOF

# 5. Healthcheck
HEALTH_URL="https://${APP}.apps.romain-ecarnot.com/api/health"
for i in 1 2 3 4 5; do
  code=$(curl -sS -o /dev/null -w "%{http_code}" "$HEALTH_URL" || echo "000")
  [ "$code" = "200" ] && break
  sleep 5
done
[ "$code" = "200" ] || { echo "::error::Healthcheck failed ($code)"; exit 1; }

# 6. Notif Telegram
source <(sops -d secrets/_common.enc.yaml | yq -o=shell)
curl -sS "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
  -d chat_id="${TELEGRAM_CHAT_ID}" \
  -d text="✅ Deploy ${APP} ${TAG} OK"
```

### 4.4 Points clés

- Le runner GA tient **toute la machinerie sensible** (clé SSH VPS, clé age
  sops, PAT GHCR). Le VPS n'exécute que `docker compose pull && up -d`.
- **Pas de git pull sur le VPS.** Le `deploy-vps/` arrive par scp depuis le
  runner (qui a fetch le tarball à la bonne SHA via GH API). Zéro besoin que
  le repo app soit cloné sur le VPS.
- **`concurrency.group: deploy-<app>`** : deux releases Buck simultanées
  s'enchaînent au lieu d'écraser le même container.
- **`cache-from/to: type=gha`** : layers cachés entre runs → le build de
  `writing-tools-mcp` qui prenait 5 min sur le VPS tombe à ~1 min la 2ᵉ fois.

### 4.5 Format de `deploy-state.yaml`

```yaml
# apps/buck/deploy-state.yaml
app: buck
app_repo: eRom/buck-writer-app
tag: buck-v1.2.3
version: v1.2.3
sha: 5f3c8a9...
deployed_at: 2026-04-26T08:30:00Z
deployed_by: github-actions
```

Les images GHCR ne sont pas listées : elles sont inférables depuis la
convention `ghcr.io/erom/<app>-*:<version>`. Le compose.yml du tag déployé
fait foi pour la liste exacte.

---

## 5. Secrets, backup, rollback

### 5.1 Secrets (sops + age)

**Layout `vps-docker-manager-prod/secrets/` :**

```
secrets/
├── buck.enc.yaml         ← OPENAI_API_KEY, RESEND_API_KEY, MCP_SHARED_SECRET, ...
├── trinity.enc.yaml      ← N8N_*, QDRANT_*, ...
├── n8n.enc.yaml
└── _common.enc.yaml      ← TELEGRAM_TOKEN, TELEGRAM_CHAT_ID
```

**Convention** : YAML clair côté édition, chiffré au repos. 1 fichier = 1 app,
clés à plat (pas de nesting). Le runner GA fait `sops -d → yq -o=shell` pour
produire un `.env` injecté dans `/opt/<app>/.env`.

**Recipients age** :
- Clé laptop Romain (`~/.config/sops/age/keys.txt`).
- Clé runner GA (stockée comme `secrets.SOPS_AGE_KEY`).
- Clé VPS (`/root/.config/sops/age/keys.txt`) pour le mode rollback parachute.
- `.sops.yaml` au root du repo prod liste les 3 recipients.

**Rotation** : skill `/deploy:secrets <app>` → `sops secrets/<app>.enc.yaml`
(ouvre $EDITOR, re-chiffre au save, commit). Propose un redeploy après modif.

### 5.2 Backup data

**Phase A — cron VPS local** (livré avec le deploy Buck v1) :

`/opt/_infra/scripts/backup-buck.sh` (générique, paramétrable par app) :

```bash
#!/usr/bin/env bash
set -euo pipefail
APP="$1"
DATA_DIR="/opt/${APP}/data"
BACKUP_DIR="/opt/_infra/backups/${APP}"
TS=$(date +%Y%m%d-%H%M%S)
mkdir -p "$BACKUP_DIR"

find "$DATA_DIR" -name "*.db" | while read db; do
  name=$(basename "$db" .db)
  sqlite3 "$db" ".backup '$BACKUP_DIR/${name}-${TS}.db'"
done

tar czf "$BACKUP_DIR/files-${TS}.tgz" \
  -C "$DATA_DIR" \
  --exclude='*.db' --exclude='*.db-wal' --exclude='*.db-shm' .

find "$BACKUP_DIR" -mtime +7 -delete
```

Cron (`/etc/cron.d/backup-buck`) :
`30 3 * * * root /opt/_infra/scripts/backup-buck.sh buck`

**Phase B — sync vers stockage externe** : ajout différé. Candidats :
Backblaze B2 (~$0.005/GB/mois) ou Hetzner Storage Box. Décision prise au
moment de l'écrire. Un nouveau spec court couvrira la Phase B.

### 5.3 Rollback

**Chemin A — UI GA (chemin normal)** :
- `vps-docker-manager-prod` → Actions → workflow `deploy` → "Run workflow"
- Inputs : `app=buck`, `tag=buck-v1.2.3`, `deploy_vps_ref=<sha>`.
- Le SHA s'obtient via `gh release list --repo eRom/buck-writer-app` ou via
  la skill `/deploy:rollback buck buck-v1.2.3` qui résout auto.

**Chemin C — script SSH parachute** :

`/opt/_infra/scripts/rollback.sh` (présent sur le VPS, ne dépend pas de GH) :

```bash
#!/usr/bin/env bash
set -euo pipefail
APP="$1"; TAG="$2"
VERSION="${TAG#*-}"
cd "/opt/${APP}/deploy-vps"
TAG="${VERSION}" docker compose pull
TAG="${VERSION}" docker compose up -d --remove-orphans
echo "✓ Rollback ${APP} → ${TAG} done."
echo "  Pense à committer dans vps-docker-manager-prod/apps/${APP}/deploy-state.yaml"
```

**Garde-fou** : retention GHCR `latest` + 10 derniers tags par image
(configuré via GitHub repo settings ou workflow `cleanup.yml` mensuel).

---

## 6. Tooling Claude

### 6.1 Skills (`vps-docker-manager-prod/.claude/skills/deploy/`)

#### `/deploy:status [app]`

Snapshot de l'état d'une app (ou de toutes) sur le VPS. Lecture pure.
Sortie Markdown : nom app, tag courant (depuis `deploy-state.yaml`), statut
containers, healthcheck HTTPS.

#### `/deploy:logs <app> [--since 10m] [--service <name>]`

Tail logs sur le VPS, filtré par service optionnel.

```bash
ssh vps "cd /opt/$APP/deploy-vps && docker compose logs --tail=200 ${SINCE:+--since $SINCE} $SERVICE"
```

#### `/deploy:rollback <app> <tag>`

Déclenche le rollback via UI GA (chemin A) avec resolution auto du SHA.

1. `gh release view "$TAG" --repo eRom/${APP}-writer-app --json targetCommitish` → SHA.
2. Récap (app, tag courant, tag cible, SHA) → confirmation Romain.
3. `gh workflow run deploy.yml --repo eRom/vps-docker-manager-prod -f app=$APP -f tag=$TAG -f deploy_vps_ref=$SHA`.
4. `gh run watch` jusqu'à completion.

Si Romain dit "use SSH" → bascule vers le chemin C.

#### `/deploy:bootstrap <app>`

Onboarde une nouvelle app (n8n, trinity, le prochain truc). Workflow
interactif :

1. Demande `app_repo`, `domain`, `services`.
2. Crée dans `vps-docker-manager-prod` :
   - `apps/<app>/deploy-state.yaml` (template vide).
   - `secrets/<app>.enc.yaml` (template sops avec `# TODO`).
   - Entrée `apps:` dans `README.md` (dashboard auto).
3. Génère dans le repo app `deploy-vps/` un squelette :
   - `compose.yml` template avec labels Traefik génériques.
   - `.github/workflows/release.yml` (matrix GHCR + dispatch, à éditer).
   - `README.md` (cheat-sheet).
4. Affiche checklist post-bootstrap : ajouter `INFRA_DISPATCH_PAT` au repo
   app, ajouter clé age recipient à `.sops.yaml`, créer DNS records.

### 6.2 Sub-agent : `deploy-doctor`

`vps-docker-manager-prod/.claude/agents/deploy-doctor.md`.

**Trigger** : manuel ou auto par les autres skills sur healthcheck failed.

**Tools** : `Bash` (ssh + curl), `Read` (configs, deploy-state), `WebFetch`
(endpoints publics). **Aucun tool d'écriture.** L'agent diagnostique, il
n'agit pas.

**Workflow interne** :
1. Lit `apps/<app>/deploy-state.yaml`.
2. SSH VPS : `docker compose ps`, `docker logs --tail 50 <chaque service>`,
   `docker stats --no-stream`.
3. Curl healthcheck endpoints publics + internes via `docker exec`.
4. Lit logs Traefik (`docker logs traefik --since 10m | grep <app>`).
5. Compare avec le précédent deploy (`git log apps/<app>/deploy-state.yaml -2`).
6. Retourne rapport hiérarchisé : verdict `HEALTHY|DEGRADED|DOWN`, cause
   probable + confiance, 3 hypothèses ordonnées, commandes suggérées.

### 6.3 Notes d'archi tooling

- Les skills vivent dans `vps-docker-manager-prod/.claude/` → uniquement
  disponibles quand le repo est ouvert. Volontaire : pas de
  `/deploy:rollback` depuis le repo Buck par accident.
- Aucune skill n'a besoin de Gerber MCP. Indépendance totale.

---

## 7. Migration J0 Buck (runbook)

### Étape 1 — Préparer `buck-writer-app`

1. `git mv vps deploy-vps`.
2. **Réécrire `deploy-vps/compose.yml`** :
   - `build:` → `image: ghcr.io/erom/buck-*:${TAG:-latest}` pour les 5 services.
   - Ajouter labels Traefik (route + tls cloudflare + middlewares) sur
     `buck-app`, `bible-ui`, `bible-mcp`, `writing-tools-mcp`.
     `markitdown-worker` reste interne.
   - Remplacer `caddy-public` par `traefik-public` partout.
3. **Supprimer** `deploy-vps/Caddyfile`, `.env.production`, `.env.trinity`,
   `deploy.sh`.
4. **Garder** `Dockerfile.app`, `Dockerfile.bible-mcp`, `Dockerfile.bible-ui`,
   `Dockerfile.writing-tools-mcp`, `docker-entrypoint.sh`,
   `writing-tools-entrypoint.py`.
5. **Créer `.github/workflows/release.yml`** (cf §4.1, trigger `buck-v*`).
6. **Supprimer** ancien `.github/workflows/deploy-vps.yml`.
7. Ajouter PAT `INFRA_DISPATCH_PAT` dans Settings → Secrets → Actions du
   repo Buck (scoped : `repo` write sur `vps-docker-manager-prod`).

### Étape 2 — Préparer `vps-docker-manager-prod`

1. Créer arborescence :
   ```
   apps/buck/deploy-state.yaml
   secrets/buck.enc.yaml          (merge ancien .env.production + .env.trinity)
   secrets/_common.enc.yaml
   scripts/deploy.sh
   scripts/rollback.sh
   scripts/backup-buck.sh
   scripts/update-state.py
   .github/workflows/deploy.yml
   .claude/skills/deploy/{status,logs,rollback,bootstrap}.md
   .claude/agents/deploy-doctor.md
   infra/dynamic/buck.yaml
   ```
2. Mettre à jour `.sops.yaml` pour ajouter recipient runner GA.
3. Ajouter secrets GA : `VPS_SSH_KEY`, `SOPS_AGE_KEY`, `VPS_HOST`,
   `INFRA_READ_PAT` (PAT scoped lecture pour `gh api tarball`).

### Étape 3 — Préparer le VPS

1. `ssh vps "mkdir -p /opt/buck/{data,deploy-vps}"`.
2. **Restaurer le snapshot data** :
   ```bash
   ssh vps "cd /opt/buck && tar xzf ~/Backups/snapshot-20260425-122029.tgz --strip-components=N data/"
   ```
   `N` à ajuster selon la structure du tgz, vérifier avec `tar tzf` avant.
3. `chown -R 1000:1000 /opt/buck/data` (UID node container, gotcha connu).
4. **Reboot du VPS** pour appliquer le kernel update en attente.
5. Cron backup : copier `backup-buck.sh` dans `/opt/_infra/scripts/` et
   ajouter ligne au `/etc/cron.d/backup-buck`.

### Étape 4 — Premier deploy

1. `git tag buck-v1.0.0-rc.1 && git push --tags` sur `buck-writer-app`.
2. Workflow `release.yml` build + push 5 images GHCR (~6-8 min première fois).
3. Dispatch vers `vps-docker-manager-prod`, workflow `deploy.yml` exécute
   `deploy.sh`.
4. Vérifs manuelles :
   - Connexion magic-link Buck OK.
   - Bible UI accessible (forward_auth Traefik OK).
   - 1 prompt avec MCP call (vérifie Bearer auth OK).
   - Upload .docx (vérifie markitdown-worker).

### Étape 5 — Stabilisation

Si tout OK pendant 24-48h : `git tag buck-v1.0.0` (sans `-rc.1`) →
re-déclenche pipeline → baseline officiel.

### Étape 6 — Rétrospective avant n8n et trinity

Court doc dans `vps-docker-manager-prod/docs/lessons-buck-onboarding.md` :
ce qui a marché, ce qui a frotté, ajustements à faire avant
`/deploy:bootstrap n8n` et `/deploy:bootstrap trinity`.

---

## 8. Critères d'acceptation

- [ ] Tag `buck-v1.0.0` sur `buck-writer-app` déclenche le pipeline complet
      sans intervention manuelle.
- [ ] Les 5 images Buck sont push sur GHCR sous `ghcr.io/erom/buck-*:v1.0.0`.
- [ ] `apps/buck/deploy-state.yaml` est commit auto sur `main` du repo
      infra prod avec un message `deploy: buck buck-v1.0.0`.
- [ ] Les 5 containers tournent sur le VPS, accessibles via
      `https://buck.apps.romain-ecarnot.com` (et sous-domaines bible/MCP).
- [ ] Healthcheck `https://buck.apps.romain-ecarnot.com/api/health`
      retourne 200.
- [ ] Forward_auth Bible UI fonctionne (test : ouvrir `bible.buck.apps.*`
      sans session → 401, avec session magic-link Buck → 200).
- [ ] Bearer auth MCP fonctionne (test : curl `bible-mcp.buck.apps.*/mcp`
      sans Bearer → 401, avec Bearer → 200).
- [ ] Notif Telegram reçue à la fin du deploy.
- [ ] Aucun build n'a tourné sur le VPS (vérification : `docker images
      --filter dangling=false` ne montre pas de layers buildés).
- [ ] Aucun secret en clair sur disque VPS sauf `/opt/buck/.env` (mode 600,
      owner root).
- [ ] `/deploy:status buck` retourne un snapshot lisible.
- [ ] `/deploy:rollback buck buck-v0.9.0` (si on simule un rollback)
      fonctionne et écrit le commit `deploy: buck buck-v0.9.0`.
- [ ] Cron backup tourne à 03:30, écrit dans `/opt/_infra/backups/buck/`.
- [ ] Le repo Trinity n'est pas touché par le deploy Buck (vérification :
      `ls -la /opt/trinity-lifeos` montre la dernière modif d'avant la
      migration).

---

## 9. Risques et mitigations

| Risque | Probabilité | Impact | Mitigation |
|---|---|---|---|
| GHCR rate limit sur les pulls VPS | faible | moyen | Auth GHCR sur le VPS (`docker login ghcr.io`) avec un PAT readonly |
| Premier build `writing-tools-mcp` timeout GA (10 min limite default) | moyen | bas | `timeout-minutes: 30` sur le job, cache GA évite les builds suivants |
| Snapshot `~/Backups/snapshot-20260425-122029.tgz` corrompu | faible | élevé | Vérification `tar tzf` avant restauration, snapshot secondaire conservé |
| Forward_auth Traefik vers `buck-app:3000` en panne au boot (race condition) | moyen | bas | `depends_on: bible-ui → buck-app` avec healthcheck, retry Traefik natif |
| Middleware Bearer file (`@file`) pas rechargé après modif | moyen | moyen | Traefik watch automatique sur `/etc/traefik/dynamic/*.yaml` ; à valider |
| Rollback à un tag dont l'image GHCR a été purgée | faible | élevé | Retention 10 derniers tags + `latest`, alerte si tentative rollback hors retention |
| `repository_dispatch` PAT expire | faible | moyen | PAT longue durée, doc rotation dans `vps-docker-manager-prod/README.md` |

---

## 10. Stack et versions

- **Traefik** : v3.6.14 (déjà en place).
- **Docker / Compose** : Docker 29 + Compose v2 (déjà installé).
- **sops** : ≥ 3.12.2 (gotcha #1 infra-bootstrap).
- **age** : ≥ 1.1.
- **GitHub Actions runners** : `ubuntu-latest`.
- **Images bases** : Node 20, Python 3.11, nginx alpine (inchangées vs legacy).
