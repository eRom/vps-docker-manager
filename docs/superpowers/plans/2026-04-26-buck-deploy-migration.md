# Buck Deploy Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrer Buck Writer du legacy `vps/deploy.sh` (Caddy + git pull + build VPS) vers le nouveau pattern `deploy-vps/` (Traefik + GHCR + sops + GA pipeline split), en livrant aussi le tooling Claude (`/deploy:*` + `deploy-doctor`) qui resservira pour onboarder n8n et trinity.

**Architecture:** Trois acteurs : (1) repo app `buck-writer-app` qui contient `deploy-vps/` et workflow `release.yml` (build + push GHCR + dispatch) ; (2) repo infra prod `vps-docker-manager-prod` (privé) qui tient secrets sops + workflow `deploy.yml` (orchestration SSH + commit deploy-state) + scripts ops + skills Claude ; (3) VPS qui exécute uniquement `docker compose pull && up -d`.

**Tech Stack:** Docker Compose v2, Traefik v3.6, GitHub Actions + GHCR, sops + age, bash scripts, Python 3 (helper YAML), Claude Code skills (Markdown + bash invocation).

**Repos touchés (3) :**
- `vps-docker-manager-prod` (privé, local : `/Users/recarnot/dev/vps-docker-manager-prod`)
- `buck-writer-app` (local : `/Users/recarnot/dev/buck-writer-app`)
- VPS Hostinger `72.62.239.98` (via SSH)

**Spec source :** `docs/superpowers/specs/2026-04-26-buck-deploy-migration-design.md`

---

## File Structure

### Dans `vps-docker-manager-prod/`

**Nouveaux fichiers :**
- `apps/buck/deploy-state.yaml` — état Buck (tag/sha/timestamp), source de vérité runtime
- `secrets/buck.enc.yaml` — secrets Buck (sops, merge ancien `.env.production` + `.env.trinity`)
- `secrets/_common.enc.yaml` — secrets partagés (Telegram bot)
- `scripts/deploy.sh` — orchestrateur deploy (runner GA)
- `scripts/rollback.sh` — parachute SSH (copié sur VPS dans `/opt/_infra/scripts/`)
- `scripts/backup-buck.sh` — backup générique paramétrable par app (cron VPS)
- `scripts/update-state.py` — helper YAML pour mettre à jour `deploy-state.yaml`
- `.github/workflows/deploy.yml` — réagit aux `repository_dispatch` et `workflow_dispatch`
- `infra/dynamic/buck.yaml` — middlewares Bearer Traefik (chargés en runtime)
- `.claude/skills/deploy/status.md` — skill `/deploy:status`
- `.claude/skills/deploy/logs.md` — skill `/deploy:logs`
- `.claude/skills/deploy/rollback.md` — skill `/deploy:rollback`
- `.claude/skills/deploy/bootstrap.md` — skill `/deploy:bootstrap`
- `.claude/agents/deploy-doctor.md` — sub-agent diagnostique
- `docs/lessons-buck-onboarding.md` — rétrospective post-migration

**Modifiés :**
- `.sops.yaml` — étendre regex pour matcher `secrets/**.enc.yaml`, ajouter recipient GA
- `README.md` — ajouter section "Apps déployées" (dashboard auto)
- `docker-compose.yml` (Traefik) — mounter `infra/dynamic/` dans le container Traefik

### Dans `buck-writer-app/`

**Renommés :**
- `vps/` → `deploy-vps/` (git mv)

**Modifiés :**
- `deploy-vps/compose.yml` — réécrit complètement : `image: ghcr.io/erom/buck-*` + labels Traefik + network `traefik-public`

**Nouveaux fichiers :**
- `.github/workflows/release.yml` — build/push GHCR matrix + dispatch vers infra prod

**Supprimés :**
- `deploy-vps/Caddyfile`
- `deploy-vps/.env.production`
- `deploy-vps/.env.trinity`
- `deploy-vps/deploy.sh`
- `.github/workflows/deploy-vps.yml`

### Sur le VPS

**Nouveaux dossiers :**
- `/opt/buck/{data,deploy-vps}/`
- `/opt/_infra/backups/buck/`
- `/opt/_infra/scripts/{rollback.sh,backup-buck.sh}` (copies depuis le repo prod)

**Configurés :**
- `/etc/cron.d/backup-buck` — cron quotidien 03:30
- Kernel reboot pour appliquer update en attente

---

## Phase 1 — Bootstrap `vps-docker-manager-prod`

**But :** Préparer toute l'infra côté repo prod **avant** de toucher Buck. Cette phase ne modifie pas le VPS, on prépare les outils et les secrets.

### Task 1.1 : Étendre `.sops.yaml` pour la nouvelle structure

**Files :**
- Modify : `vps-docker-manager-prod/.sops.yaml`

**Pré-requis :** Générer la clé age publique du runner GA. Dans `vps-docker-manager-prod/`, lancer :
```bash
age-keygen -o /tmp/ga-runner.txt
# Note : la clé PRIVÉE (commence par AGE-SECRET-KEY-1...) sera ajoutée comme
# secret GitHub `SOPS_AGE_KEY` à la Task 1.10. La clé PUBLIQUE (commence par
# age1...) va dans .sops.yaml ci-dessous.
grep "public key:" /tmp/ga-runner.txt
```

- [ ] **Step 1 : Lire le `.sops.yaml` actuel pour repérer les clés existantes**

```bash
cat /Users/recarnot/dev/vps-docker-manager-prod/.sops.yaml
```

- [ ] **Step 2 : Réécrire `.sops.yaml` avec regex étendue + recipient GA**

```yaml
# vps-docker-manager-prod/.sops.yaml
creation_rules:
  - path_regex: '(^|/)secrets(\.enc)?\.yaml$|^secrets/.*\.enc\.yaml$'
    age:
      - age1y4a0mfx6vscx9dpmknfhkrmrn0ufte096wffv50qfq6f5ldl7spqt7lu4j  # laptop
      - age133dvxfd72c4lwwz6k9vy8402v6gt2rl74zqyzg0m32tgqlxks3xq3q4zhk  # VPS
      - age1XXXXXX_RUNNER_GA_PUBKEY_XXXXXX                              # runner GA (à remplir)
  - path_regex: \.env\.enc$
    age:
      - age1y4a0mfx6vscx9dpmknfhkrmrn0ufte096wffv50qfq6f5ldl7spqt7lu4j
      - age133dvxfd72c4lwwz6k9vy8402v6gt2rl74zqyzg0m32tgqlxks3xq3q4zhk
      - age1XXXXXX_RUNNER_GA_PUBKEY_XXXXXX
```

Remplacer `age1XXXXXX_RUNNER_GA_PUBKEY_XXXXXX` (2 occurrences) par la clé publique générée au pré-requis.

- [ ] **Step 3 : Re-chiffrer le `secrets.enc.yaml` existant avec le nouveau set de recipients**

```bash
cd /Users/recarnot/dev/vps-docker-manager-prod
sops updatekeys secrets.enc.yaml
# Confirmer l'ajout du nouveau recipient
```

- [ ] **Step 4 : Vérifier que les 3 clés peuvent déchiffrer**

```bash
sops -d secrets.enc.yaml > /dev/null && echo "OK laptop"
# Pour le VPS : ssh root@72.62.239.98 "sops -d /opt/_infra/secrets.enc.yaml > /dev/null && echo OK"
# Pour GA : test viendra à la Task 3.4 (premier deploy)
```

- [ ] **Step 5 : Commit**

```bash
cd /Users/recarnot/dev/vps-docker-manager-prod
git add .sops.yaml secrets.enc.yaml
git commit -m "chore(sops): extend regex for per-app secrets + add GA runner recipient"
```

### Task 1.2 : Créer l'arborescence `apps/` et `secrets/`

**Files :**
- Create : `vps-docker-manager-prod/apps/buck/deploy-state.yaml`
- Create : `vps-docker-manager-prod/apps/buck/.gitkeep` (si dossier vide ailleurs)
- Create : `vps-docker-manager-prod/secrets/_common.enc.yaml` (sops)
- Create : `vps-docker-manager-prod/secrets/buck.enc.yaml` (sops, contenu réel rempli à la Task 1.3)

- [ ] **Step 1 : Créer le dossier `apps/buck/` avec deploy-state vide**

```bash
mkdir -p /Users/recarnot/dev/vps-docker-manager-prod/apps/buck
cat > /Users/recarnot/dev/vps-docker-manager-prod/apps/buck/deploy-state.yaml <<'EOF'
app: buck
app_repo: eRom/buck-writer-app
tag: null
version: null
sha: null
deployed_at: null
deployed_by: null
EOF
```

- [ ] **Step 2 : Créer `secrets/` et le fichier `_common.enc.yaml`**

D'abord en clair, puis chiffrer :

```bash
mkdir -p /Users/recarnot/dev/vps-docker-manager-prod/secrets
cat > /tmp/_common.yaml <<'EOF'
# Secrets partagés entre apps (utilisés par scripts/deploy.sh, backup-*.sh)
TELEGRAM_TOKEN: <à remplir avec la valeur du bot @TrinityClaudeCode_bot>
TELEGRAM_CHAT_ID: <à remplir>
EOF
# Remplir manuellement les 2 valeurs depuis 1Password ou ancien .env Trinity
$EDITOR /tmp/_common.yaml
sops -e /tmp/_common.yaml > /Users/recarnot/dev/vps-docker-manager-prod/secrets/_common.enc.yaml
shred -u /tmp/_common.yaml
```

- [ ] **Step 3 : Vérifier que `_common.enc.yaml` est bien chiffré**

```bash
head -3 /Users/recarnot/dev/vps-docker-manager-prod/secrets/_common.enc.yaml
# Doit montrer du contenu chiffré (ENC[AES256_GCM,...]) PAS du YAML clair
```

- [ ] **Step 4 : Commit (sans `secrets/buck.enc.yaml` qui viendra à la Task 1.3)**

```bash
cd /Users/recarnot/dev/vps-docker-manager-prod
git add apps/buck/deploy-state.yaml secrets/_common.enc.yaml
git commit -m "feat(apps): bootstrap apps/buck + secrets/_common"
```

### Task 1.3 : Migrer secrets Buck depuis l'ancien `.env.production` + `.env.trinity` vers `secrets/buck.enc.yaml`

**Files :**
- Read : `/Users/recarnot/dev/buck-writer-app/vps/.env.production`
- Read : `/Users/recarnot/dev/buck-writer-app/vps/.env.trinity`
- Create : `vps-docker-manager-prod/secrets/buck.enc.yaml`

- [ ] **Step 1 : Lister toutes les variables des 2 fichiers .env existants**

```bash
grep -hE '^[A-Z_]+=' /Users/recarnot/dev/buck-writer-app/vps/.env.production \
                    /Users/recarnot/dev/buck-writer-app/vps/.env.trinity \
  | cut -d= -f1 | sort -u
```

- [ ] **Step 2 : Créer le YAML clair en mergeant les 2 sources**

```bash
cat > /tmp/buck.yaml <<'EOF'
# === Buck app secrets ===
OPENAI_API_KEY: <copier depuis .env.production>
OPENAI_EMBEDDING_MODEL: text-embedding-3-small
RESEND_API_KEY: <copier>
GEMINI_API_KEY: <copier>
GOOGLE_API_KEY: <copier>
XAI_API_KEY: <copier>
SUPABASE_URL: <copier>
SUPABASE_SERVICE_ROLE_KEY: <copier>

# === MCP Bearer (shared entre Buck app + Bearer middleware Traefik) ===
MCP_SHARED_SECRET: <copier — DOIT être identique entre .env.production et .env.trinity>

# === Bible UI basicauth (legacy, à supprimer une fois SSO Bible vérifié) ===
BIBLE_USER: romain
BIBLE_PASSWORD_HASH: <copier depuis .env.production si présent>

# === Buck magic-link (auth interne) ===
EMAIL_FROM: <copier>
APP_URL: https://buck.apps.romain-ecarnot.com
SESSION_SECRET: <copier>

# === MarkItDown internal token ===
MARKITDOWN_INTERNAL_TOKEN: <copier>
MARKITDOWN_URL: http://markitdown-worker:8000

# === Public URLs MCP (pour OpenAI Responses connector) ===
MCP_BIBLE_URL: https://bible-mcp.buck.apps.romain-ecarnot.com
MCP_WRITING_TOOLS_URL: https://writing-mcp.buck.apps.romain-ecarnot.com
VITE_BIBLE_UI_URL: https://bible.buck.apps.romain-ecarnot.com
EOF
$EDITOR /tmp/buck.yaml  # remplir les <copier>
```

**Note importante** : les domaines passent de `*.romain-ecarnot.com` (legacy Caddy) à `*.apps.romain-ecarnot.com` (nouveau Traefik wildcard). Vérifier que les valeurs reflètent bien les nouveaux domaines.

- [ ] **Step 3 : Chiffrer et nettoyer le clair**

```bash
sops -e /tmp/buck.yaml > /Users/recarnot/dev/vps-docker-manager-prod/secrets/buck.enc.yaml
shred -u /tmp/buck.yaml
```

- [ ] **Step 4 : Vérifier déchiffrement et lisibilité**

```bash
sops -d /Users/recarnot/dev/vps-docker-manager-prod/secrets/buck.enc.yaml | head -5
# Doit montrer le YAML clair, pas d'erreur
```

- [ ] **Step 5 : Commit**

```bash
cd /Users/recarnot/dev/vps-docker-manager-prod
git add secrets/buck.enc.yaml
git commit -m "feat(secrets): add buck.enc.yaml (migrated from .env.production + .env.trinity)"
```

### Task 1.4 : Créer `scripts/update-state.py`

**Files :**
- Create : `vps-docker-manager-prod/scripts/update-state.py`

- [ ] **Step 1 : Écrire le script Python**

```python
#!/usr/bin/env python3
"""Update apps/<app>/deploy-state.yaml with current deploy info.

Used by .github/workflows/deploy.yml right before committing the state file.
"""
import argparse
import datetime
import os
import sys
from pathlib import Path

import yaml


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--tag", required=True, help="e.g. buck-v1.2.3")
    parser.add_argument("--ref", required=True, help="commit SHA from app repo")
    parser.add_argument(
        "--actor",
        default=os.environ.get("GITHUB_ACTOR", "manual"),
        help="who triggered the deploy",
    )
    args = parser.parse_args()

    state_path = Path(f"apps/{args.app}/deploy-state.yaml")
    if not state_path.exists():
        print(f"ERROR: {state_path} not found", file=sys.stderr)
        return 1

    state = yaml.safe_load(state_path.read_text()) or {}
    version = args.tag.split("-", 1)[1] if "-" in args.tag else args.tag

    state.update(
        app=args.app,
        tag=args.tag,
        version=version,
        sha=args.ref,
        deployed_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        deployed_by=args.actor,
    )
    state.setdefault("app_repo", f"eRom/{args.app}-writer-app")  # default convention

    state_path.write_text(yaml.safe_dump(state, sort_keys=False, default_flow_style=False))
    print(f"Updated {state_path}: {args.tag} ({args.ref[:7]})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2 : Rendre exécutable**

```bash
chmod +x /Users/recarnot/dev/vps-docker-manager-prod/scripts/update-state.py
```

- [ ] **Step 3 : Smoke test local**

```bash
cd /Users/recarnot/dev/vps-docker-manager-prod
python3 scripts/update-state.py --app buck --tag buck-v0.0.1-test --ref abcdef1234 --actor test
cat apps/buck/deploy-state.yaml
# Doit montrer tag/version/sha mis à jour
git checkout -- apps/buck/deploy-state.yaml  # rollback du test
```

- [ ] **Step 4 : Commit**

```bash
git add scripts/update-state.py
git commit -m "feat(scripts): add update-state.py helper for deploy-state.yaml"
```

### Task 1.5 : Créer `scripts/deploy.sh`

**Files :**
- Create : `vps-docker-manager-prod/scripts/deploy.sh`

- [ ] **Step 1 : Écrire le script complet**

```bash
#!/usr/bin/env bash
# Orchestrateur de deploy d'une app sur le VPS.
# Exécuté par .github/workflows/deploy.yml (pas localement).
#
# Variables d'environnement requises :
#   APP             : nom de l'app (ex: buck)
#   APP_REPO        : owner/name du repo app (ex: eRom/buck-writer-app)
#   TAG             : tag complet (ex: buck-v1.2.3)
#   DEPLOY_VPS_REF  : SHA du commit sur app_repo
#   VPS_HOST        : adresse IP du VPS
#   GH_TOKEN        : PAT lecture pour gh api tarball
#   SOPS_AGE_KEY_FILE: path vers la clé age (défaut: ~/.config/sops/age/keys.txt)
set -euo pipefail

VERSION="${TAG#*-}"   # buck-v1.2.3 → v1.2.3
echo "▶ Deploying ${APP} ${TAG} (version=${VERSION}, ref=${DEPLOY_VPS_REF:0:7})"

# 1. Decrypt secrets pour cette app → fichier .env temporaire
sops -d secrets/${APP}.enc.yaml | yq -o=shell > /tmp/${APP}.env
echo "TAG=${VERSION}" >> /tmp/${APP}.env

# 2. Récupère le tarball deploy-vps/ depuis le repo app à la SHA exacte
gh api "repos/${APP_REPO}/tarball/${DEPLOY_VPS_REF}" > /tmp/app.tar.gz
mkdir -p /tmp/extract
tar xzf /tmp/app.tar.gz -C /tmp/extract --strip-components=1
DEPLOY_DIR=/tmp/extract/deploy-vps
[ -d "$DEPLOY_DIR" ] || { echo "ERROR: deploy-vps/ not found in tarball"; exit 1; }

# 3. Push sur VPS dans /opt/${APP}/
ssh -i ~/.ssh/id_deploy -o StrictHostKeyChecking=no root@${VPS_HOST} \
  "mkdir -p /opt/${APP}/{data,deploy-vps}"
scp -i ~/.ssh/id_deploy -o StrictHostKeyChecking=no -r \
  ${DEPLOY_DIR}/* root@${VPS_HOST}:/opt/${APP}/deploy-vps/
scp -i ~/.ssh/id_deploy -o StrictHostKeyChecking=no \
  /tmp/${APP}.env root@${VPS_HOST}:/opt/${APP}/.env
ssh -i ~/.ssh/id_deploy root@${VPS_HOST} "chmod 600 /opt/${APP}/.env"

# 4. Pull + up
ssh -i ~/.ssh/id_deploy root@${VPS_HOST} bash <<EOF
  set -euo pipefail
  cd /opt/${APP}/deploy-vps
  docker compose --env-file /opt/${APP}/.env pull
  docker compose --env-file /opt/${APP}/.env up -d --remove-orphans
  sleep 10
  docker compose --env-file /opt/${APP}/.env ps
EOF

# 5. Healthcheck
HEALTH_URL="https://${APP}.apps.romain-ecarnot.com/api/health"
echo "▶ Healthcheck: $HEALTH_URL"
code="000"
for i in 1 2 3 4 5; do
  code=$(curl -sS -o /dev/null -w "%{http_code}" "$HEALTH_URL" || echo "000")
  echo "  attempt $i: HTTP $code"
  [ "$code" = "200" ] && break
  sleep 5
done
[ "$code" = "200" ] || { echo "::error::Healthcheck failed (HTTP $code)"; exit 1; }

# 6. Notif Telegram (best-effort, ne fait pas échouer le deploy)
if [ -f secrets/_common.enc.yaml ]; then
  source <(sops -d secrets/_common.enc.yaml | yq -o=shell)
  curl -sS "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d text="✅ Deploy ${APP} ${TAG} OK (${DEPLOY_VPS_REF:0:7})" \
    > /dev/null || echo "::warning::Telegram notif failed"
fi

# 7. Cleanup
rm -f /tmp/${APP}.env /tmp/app.tar.gz
rm -rf /tmp/extract

echo "✓ Deploy ${APP} ${TAG} done."
```

- [ ] **Step 2 : Rendre exécutable**

```bash
chmod +x /Users/recarnot/dev/vps-docker-manager-prod/scripts/deploy.sh
```

- [ ] **Step 3 : Lint shellcheck (smoke test syntaxe)**

```bash
shellcheck /Users/recarnot/dev/vps-docker-manager-prod/scripts/deploy.sh || true
# Les warnings SC2086 sur ${TAG} sont OK (on veut le splitting dans certains cas)
```

- [ ] **Step 4 : Commit**

```bash
cd /Users/recarnot/dev/vps-docker-manager-prod
git add scripts/deploy.sh
git commit -m "feat(scripts): add deploy.sh orchestrator (sops decrypt + scp + compose pull/up + healthcheck)"
```

### Task 1.6 : Créer `scripts/rollback.sh`

**Files :**
- Create : `vps-docker-manager-prod/scripts/rollback.sh`

- [ ] **Step 1 : Écrire le script**

```bash
#!/usr/bin/env bash
# Rollback parachute (chemin C). Exécuté SSH directement sur le VPS quand
# GitHub Actions n'est pas accessible. Re-pull une image GHCR taguée et up.
#
# Usage : ./rollback.sh <app> <tag>
# Exemple : ./rollback.sh buck buck-v1.2.3
set -euo pipefail

APP="${1:?Usage: $0 <app> <tag>}"
TAG="${2:?Usage: $0 <app> <tag>}"
VERSION="${TAG#*-}"   # buck-v1.2.3 → v1.2.3

DEPLOY_DIR="/opt/${APP}/deploy-vps"
ENV_FILE="/opt/${APP}/.env"

[ -d "$DEPLOY_DIR" ] || { echo "ERROR: $DEPLOY_DIR missing — l'app n'a jamais été déployée ?"; exit 1; }
[ -f "$ENV_FILE" ]   || { echo "ERROR: $ENV_FILE missing"; exit 1; }

echo "▶ Rollback ${APP} → ${TAG} (version=${VERSION})"

# Patcher TAG dans le .env (en place, backup .bak)
cp "$ENV_FILE" "${ENV_FILE}.bak-$(date +%s)"
if grep -q "^TAG=" "$ENV_FILE"; then
  sed -i "s|^TAG=.*|TAG=${VERSION}|" "$ENV_FILE"
else
  echo "TAG=${VERSION}" >> "$ENV_FILE"
fi

cd "$DEPLOY_DIR"
docker compose --env-file "$ENV_FILE" pull
docker compose --env-file "$ENV_FILE" up -d --remove-orphans

echo "✓ Rollback ${APP} → ${TAG} done."
echo ""
echo "  Pense à committer dans vps-docker-manager-prod :"
echo "    cd vps-docker-manager-prod"
echo "    python3 scripts/update-state.py --app ${APP} --tag ${TAG} --ref <SHA> --actor manual-rollback"
echo "    git add apps/${APP}/deploy-state.yaml"
echo "    git commit -m 'rollback: ${APP} → ${TAG} (manual)' && git push"
```

- [ ] **Step 2 : Rendre exécutable**

```bash
chmod +x /Users/recarnot/dev/vps-docker-manager-prod/scripts/rollback.sh
```

- [ ] **Step 3 : Commit**

```bash
cd /Users/recarnot/dev/vps-docker-manager-prod
git add scripts/rollback.sh
git commit -m "feat(scripts): add rollback.sh (SSH parachute, no GH dependency)"
```

### Task 1.7 : Créer `scripts/backup-buck.sh` (générique)

**Files :**
- Create : `vps-docker-manager-prod/scripts/backup-buck.sh`

Note : le script s'appelle `backup-buck.sh` mais accepte n'importe quelle app en argument. C'est juste qu'il sera invoqué via cron pour Buck en premier.

- [ ] **Step 1 : Écrire le script**

```bash
#!/usr/bin/env bash
# Backup générique : SQLite atomique + tarball reste data/. Exécuté par cron VPS.
# Usage : ./backup-buck.sh <app>
# Exemple : ./backup-buck.sh buck   (depuis cron : tous les jours 03:30)
set -euo pipefail

APP="${1:?Usage: $0 <app>}"
DATA_DIR="/opt/${APP}/data"
BACKUP_DIR="/opt/_infra/backups/${APP}"
TS=$(date +%Y%m%d-%H%M%S)

[ -d "$DATA_DIR" ] || { echo "ERROR: $DATA_DIR missing"; exit 1; }
mkdir -p "$BACKUP_DIR"

# 1. SQLite atomique pour chaque .db trouvé
find "$DATA_DIR" -type f -name "*.db" 2>/dev/null | while read -r db; do
  name=$(basename "$db" .db)
  sqlite3 "$db" ".backup '$BACKUP_DIR/${name}-${TS}.db'"
  echo "  ✓ $db → ${name}-${TS}.db"
done

# 2. Tarball pour le reste
tar czf "$BACKUP_DIR/files-${TS}.tgz" \
  -C "$DATA_DIR" \
  --exclude='*.db' --exclude='*.db-wal' --exclude='*.db-shm' \
  . 2>/dev/null
echo "  ✓ tarball files-${TS}.tgz"

# 3. Retention 7j
deleted=$(find "$BACKUP_DIR" -mtime +7 -type f -delete -print | wc -l)
echo "  → cleaned $deleted backups older than 7d"

# 4. Disk usage
echo "  → $BACKUP_DIR usage: $(du -sh "$BACKUP_DIR" | cut -f1)"
```

- [ ] **Step 2 : Rendre exécutable**

```bash
chmod +x /Users/recarnot/dev/vps-docker-manager-prod/scripts/backup-buck.sh
```

- [ ] **Step 3 : Commit**

```bash
cd /Users/recarnot/dev/vps-docker-manager-prod
git add scripts/backup-buck.sh
git commit -m "feat(scripts): add backup-buck.sh (SQLite atomic + tarball, generic per-app)"
```

### Task 1.8 : Créer `infra/dynamic/buck.yaml` (middlewares Bearer Traefik)

**Files :**
- Create : `vps-docker-manager-prod/infra/dynamic/buck.yaml`
- Modify : `vps-docker-manager-prod/docker-compose.yml` (Traefik mount du dossier)
- Modify : `vps-docker-manager-prod/traefik/traefik.yml` (configurer file provider)

- [ ] **Step 1 : Lire la config Traefik actuelle**

```bash
cat /Users/recarnot/dev/vps-docker-manager-prod/traefik/traefik.yml
cat /Users/recarnot/dev/vps-docker-manager-prod/docker-compose.yml
```

- [ ] **Step 2 : Créer le dossier et le fichier middleware Buck**

```bash
mkdir -p /Users/recarnot/dev/vps-docker-manager-prod/infra/dynamic
cat > /Users/recarnot/dev/vps-docker-manager-prod/infra/dynamic/buck.yaml <<'EOF'
# Middlewares Bearer pour les MCP Buck. Le secret est injecté par
# substitution sed dans scripts/deploy.sh à partir de secrets/buck.enc.yaml.
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
EOF
```

- [ ] **Step 3 : Vérifier que `traefik.yml` configure bien le file provider sur ce dossier**

Dans `traefik/traefik.yml`, la section `providers` doit contenir :

```yaml
providers:
  docker:
    exposedByDefault: false
    network: traefik-public
  file:
    directory: /etc/traefik/dynamic
    watch: true
```

Si pas le cas, ajouter le bloc `file:`.

- [ ] **Step 4 : Mounter le dossier `infra/dynamic/` dans le container Traefik**

Modifier `vps-docker-manager-prod/docker-compose.yml`, dans le service `traefik`, section `volumes:` ajouter :

```yaml
      - ./infra/dynamic:/etc/traefik/dynamic:ro
```

- [ ] **Step 5 : Modifier `scripts/deploy.sh` pour faire la substitution sed lors du deploy**

Insérer ce bloc dans `scripts/deploy.sh` juste après la décryption des secrets (étape 1 du script), avant la copie sur VPS :

```bash
# 1bis. Patcher les middlewares Traefik avec les secrets Bearer (pour Buck uniquement)
if [ -f infra/dynamic/${APP}.yaml ] && grep -q "__MCP_SHARED_SECRET__" infra/dynamic/${APP}.yaml; then
  MCP_SECRET=$(grep "^MCP_SHARED_SECRET=" /tmp/${APP}.env | cut -d= -f2-)
  if [ -n "$MCP_SECRET" ]; then
    cp infra/dynamic/${APP}.yaml /tmp/${APP}-middleware.yaml
    sed -i "s|__MCP_SHARED_SECRET__|${MCP_SECRET}|g" /tmp/${APP}-middleware.yaml
    scp -i ~/.ssh/id_deploy /tmp/${APP}-middleware.yaml root@${VPS_HOST}:/opt/_infra/infra/dynamic/${APP}.yaml
    rm /tmp/${APP}-middleware.yaml
    echo "  ✓ Patched Traefik middleware ${APP}.yaml on VPS"
  fi
fi
```

- [ ] **Step 6 : Re-test shellcheck deploy.sh**

```bash
shellcheck /Users/recarnot/dev/vps-docker-manager-prod/scripts/deploy.sh || true
```

- [ ] **Step 7 : Commit**

```bash
cd /Users/recarnot/dev/vps-docker-manager-prod
git add infra/ docker-compose.yml traefik/traefik.yml scripts/deploy.sh
git commit -m "feat(infra): add dynamic Traefik middlewares + Bearer substitution flow"
```

### Task 1.9 : Créer `.github/workflows/deploy.yml`

**Files :**
- Create : `vps-docker-manager-prod/.github/workflows/deploy.yml`

- [ ] **Step 1 : Créer le dossier et écrire le workflow**

```bash
mkdir -p /Users/recarnot/dev/vps-docker-manager-prod/.github/workflows
```

```yaml
# vps-docker-manager-prod/.github/workflows/deploy.yml
name: deploy
on:
  repository_dispatch:
    types: [app-release]
  workflow_dispatch:
    inputs:
      app:
        required: true
        type: string
        description: "App slug (ex: buck)"
      app_repo:
        required: true
        type: string
        description: "App repo owner/name (ex: eRom/buck-writer-app)"
      tag:
        required: true
        type: string
        description: "Full tag (ex: buck-v1.2.3)"
      deploy_vps_ref:
        required: true
        type: string
        description: "Commit SHA on app_repo"

concurrency:
  group: deploy-${{ github.event.client_payload.app || inputs.app }}
  cancel-in-progress: false

permissions:
  contents: write   # pour committer deploy-state.yaml

jobs:
  deploy:
    runs-on: ubuntu-latest
    timeout-minutes: 15
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
        with:
          token: ${{ secrets.GITHUB_TOKEN }}

      - name: Install sops + yq
        run: |
          curl -sLo /usr/local/bin/sops https://github.com/getsops/sops/releases/download/v3.12.2/sops-v3.12.2.linux.amd64
          chmod +x /usr/local/bin/sops
          sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
          sudo chmod +x /usr/local/bin/yq

      - name: Setup SSH + age
        run: |
          mkdir -p ~/.ssh ~/.config/sops/age
          echo "${{ secrets.VPS_SSH_KEY }}" > ~/.ssh/id_deploy
          chmod 600 ~/.ssh/id_deploy
          echo "${{ secrets.SOPS_AGE_KEY }}" > ~/.config/sops/age/keys.txt
          ssh-keyscan -H ${{ secrets.VPS_HOST }} >> ~/.ssh/known_hosts 2>/dev/null

      - name: Update deploy-state.yaml + commit
        env:
          GITHUB_ACTOR_INPUT: ${{ github.actor }}
        run: |
          pip install --quiet pyyaml
          python3 scripts/update-state.py \
            --app "${{ steps.vars.outputs.app }}" \
            --tag "${{ steps.vars.outputs.tag }}" \
            --ref "${{ steps.vars.outputs.ref }}" \
            --actor "$GITHUB_ACTOR_INPUT"
          git config user.name "deploy-bot"
          git config user.email "deploy-bot@romain-ecarnot.com"
          git add apps/${{ steps.vars.outputs.app }}/deploy-state.yaml
          git commit -m "deploy: ${{ steps.vars.outputs.app }} ${{ steps.vars.outputs.tag }}"
          git push

      - name: Run deploy.sh
        env:
          APP: ${{ steps.vars.outputs.app }}
          APP_REPO: ${{ steps.vars.outputs.app_repo }}
          TAG: ${{ steps.vars.outputs.tag }}
          DEPLOY_VPS_REF: ${{ steps.vars.outputs.ref }}
          VPS_HOST: ${{ secrets.VPS_HOST }}
          GH_TOKEN: ${{ secrets.INFRA_READ_PAT }}
        run: ./scripts/deploy.sh

      - name: Cleanup SSH key
        if: always()
        run: rm -f ~/.ssh/id_deploy
```

- [ ] **Step 2 : Commit**

```bash
cd /Users/recarnot/dev/vps-docker-manager-prod
git add .github/workflows/deploy.yml
git commit -m "feat(ci): add deploy workflow (repository_dispatch + workflow_dispatch)"
```

### Task 1.10 : Configurer secrets GitHub Actions du repo prod

**Files :** aucun fichier à toucher — c'est de la conf GitHub.

- [ ] **Step 1 : Ajouter `VPS_SSH_KEY`**

Récupérer la clé SSH privée existante et l'ajouter comme secret :

```bash
cat ~/.ssh/id_vps20260131
# Copier-coller la clé privée complète (incluant les lignes BEGIN/END)
```

Aller sur `https://github.com/eRom/vps-docker-manager-prod/settings/secrets/actions` → "New repository secret" → name=`VPS_SSH_KEY`, value=la clé privée.

- [ ] **Step 2 : Ajouter `VPS_HOST`**

Name=`VPS_HOST`, value=`72.62.239.98`.

- [ ] **Step 3 : Ajouter `SOPS_AGE_KEY`**

Récupérer la clé age privée du runner GA générée à la Task 1.1 :

```bash
cat /tmp/ga-runner.txt
# Copier la ligne AGE-SECRET-KEY-1...
```

Name=`SOPS_AGE_KEY`, value=`AGE-SECRET-KEY-1...`.

Puis nettoyer : `shred -u /tmp/ga-runner.txt`.

- [ ] **Step 4 : Créer `INFRA_READ_PAT`**

Aller sur `https://github.com/settings/personal-access-tokens/new` (fine-grained PAT) :
- Resource owner : `eRom`
- Repository access : "Selected" → `buck-writer-app` (et plus tard ajouter `n8n-stack`, `trinity-stack`)
- Permissions : "Repository contents" = **Read-only**
- Expiration : 1 an

Copier le PAT (`github_pat_...`), l'ajouter comme secret `INFRA_READ_PAT` du repo `vps-docker-manager-prod`.

- [ ] **Step 5 : Vérifier la liste des secrets**

```bash
gh secret list --repo eRom/vps-docker-manager-prod
# Doit lister : VPS_SSH_KEY, VPS_HOST, SOPS_AGE_KEY, INFRA_READ_PAT
```

(Pas de commit, pas de fichier modifié.)

---

## Phase 2 — Préparer `buck-writer-app`

**But :** Refactor le repo Buck pour le nouveau pattern `deploy-vps/` + workflow `release.yml` GHCR.

### Task 2.1 : Renommer `vps/` → `deploy-vps/`

**Files :**
- Move : `buck-writer-app/vps/` → `buck-writer-app/deploy-vps/`

- [ ] **Step 1 : Vérifier qu'on est sur main + propre**

```bash
cd /Users/recarnot/dev/buck-writer-app
git status
# Doit être propre. Si pas : stash ou commit avant.
```

- [ ] **Step 2 : git mv**

```bash
git mv vps deploy-vps
```

- [ ] **Step 3 : Trouver et corriger toutes les références à `vps/` dans le code/scripts**

```bash
grep -rn "vps/" --include="*.md" --include="*.json" --include="*.ts" --include="*.sh" --include="*.yml" --include="*.yaml" --include="*.mjs" --include="*.toml" .
```

Pour chaque match, remplacer `vps/` → `deploy-vps/`. Probable : `package.json` scripts (`docker compose -f vps/compose.local.yml`), `README.md`, `CLAUDE.md`, `.mcp.json`. Faire les remplacements un par un.

- [ ] **Step 4 : Smoke test**

```bash
# Lancer le dev hybride existant (compose.local.yml) — doit marcher comme avant
cd /Users/recarnot/dev/buck-writer-app
docker compose -f deploy-vps/compose.local.yml config > /dev/null
# Doit pas planter
```

- [ ] **Step 5 : Commit**

```bash
git add -A
git commit -m "refactor(deploy): rename vps/ → deploy-vps/ (new pattern)"
```

### Task 2.2 : Réécrire `deploy-vps/compose.yml` avec image GHCR + labels Traefik

**Files :**
- Modify : `buck-writer-app/deploy-vps/compose.yml` (réécriture complète)
- Delete : `buck-writer-app/deploy-vps/Caddyfile`
- Delete : `buck-writer-app/deploy-vps/.env.production`
- Delete : `buck-writer-app/deploy-vps/.env.trinity`

- [ ] **Step 1 : Backup le compose actuel pour référence**

```bash
cp /Users/recarnot/dev/buck-writer-app/deploy-vps/compose.yml /tmp/compose-legacy.yml
```

- [ ] **Step 2 : Réécrire `compose.yml`**

```yaml
# buck-writer-app/deploy-vps/compose.yml
# Production deploy. Images pulled from GHCR, routing via Traefik labels.
# - Le tag des images est injecté via ${TAG} dans /opt/buck/.env (par deploy.sh).
# - Les middlewares Bearer (bible-mcp-bearer, writing-mcp-bearer) vivent dans
#   vps-docker-manager-prod/infra/dynamic/buck.yaml (déchiffrés et substitués
#   au moment du deploy). Référencés ici par @file.
# - Network traefik-public est créé par infra-bootstrap (déjà en place sur VPS).

services:
  buck-app:
    image: ghcr.io/erom/buck-app:${TAG:-latest}
    container_name: buck-app
    restart: unless-stopped
    env_file: /opt/buck/.env
    environment:
      - WEB_DIST_ROOT=/app/web-dist
      - WORKSPACE_DIR=/app/workspace
      - DATABASE_URL=file:/app/data/buck.db
    volumes:
      - /opt/buck/data/db:/app/data
      - /opt/buck/data/workspace:/app/workspace
    networks: [traefik-public, internal]
    depends_on:
      - bible-mcp
      - writing-tools-mcp
      - markitdown-worker
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O - http://127.0.0.1:3000/api/health || exit 1"]
      interval: 30s
      timeout: 3s
      retries: 3
    labels:
      - traefik.enable=true
      - traefik.docker.network=traefik-public
      - traefik.http.routers.buck.rule=Host(`buck.apps.romain-ecarnot.com`)
      - traefik.http.routers.buck.entrypoints=websecure
      - traefik.http.routers.buck.tls.certresolver=cloudflare
      - traefik.http.services.buck.loadbalancer.server.port=3000

  bible-ui:
    image: ghcr.io/erom/buck-bible-ui:${TAG:-latest}
    container_name: buck-bible-ui
    restart: unless-stopped
    networks: [traefik-public, internal]
    depends_on:
      - bible-mcp
    labels:
      - traefik.enable=true
      - traefik.docker.network=traefik-public
      - traefik.http.middlewares.buck-sso.forwardauth.address=http://buck-app:3000/api/auth/verify-session
      - traefik.http.middlewares.buck-sso.forwardauth.authResponseHeaders=X-User-Id
      - traefik.http.routers.bible-ui.rule=Host(`bible.buck.apps.romain-ecarnot.com`)
      - traefik.http.routers.bible-ui.middlewares=buck-sso@docker
      - traefik.http.routers.bible-ui.entrypoints=websecure
      - traefik.http.routers.bible-ui.tls.certresolver=cloudflare
      - traefik.http.services.bible-ui.loadbalancer.server.port=8080

  bible-mcp:
    image: ghcr.io/erom/buck-bible-mcp:${TAG:-latest}
    container_name: buck-bible-mcp
    restart: unless-stopped
    env_file: /opt/buck/.env
    environment:
      BIBLE_DB_PATH: /app/data/bible.db
      BIBLE_HTTP_PORT: '7801'
    volumes:
      - /opt/buck/data/bible:/app/data
    networks: [traefik-public, internal]
    labels:
      - traefik.enable=true
      - traefik.docker.network=traefik-public
      - traefik.http.routers.bible-mcp.rule=Host(`bible-mcp.buck.apps.romain-ecarnot.com`)
      - traefik.http.routers.bible-mcp.middlewares=bible-mcp-bearer@file
      - traefik.http.routers.bible-mcp.entrypoints=websecure
      - traefik.http.routers.bible-mcp.tls.certresolver=cloudflare
      - traefik.http.services.bible-mcp.loadbalancer.server.port=7801

  writing-tools-mcp:
    image: ghcr.io/erom/buck-writing-tools-mcp:${TAG:-latest}
    container_name: buck-writing-tools-mcp
    restart: unless-stopped
    env_file: /opt/buck/.env
    networks: [traefik-public, internal]
    healthcheck:
      test: ["CMD-SHELL", "wget -q --spider http://127.0.0.1:7802/mcp || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 60s
    labels:
      - traefik.enable=true
      - traefik.docker.network=traefik-public
      - traefik.http.routers.writing-mcp.rule=Host(`writing-mcp.buck.apps.romain-ecarnot.com`)
      - traefik.http.routers.writing-mcp.middlewares=writing-mcp-bearer@file
      - traefik.http.routers.writing-mcp.entrypoints=websecure
      - traefik.http.routers.writing-mcp.tls.certresolver=cloudflare
      - traefik.http.services.writing-mcp.loadbalancer.server.port=7802

  markitdown-worker:
    image: ghcr.io/erom/buck-markitdown-worker:${TAG:-latest}
    container_name: buck-markitdown-worker
    restart: unless-stopped
    env_file: /opt/buck/.env
    environment:
      OCR_LANGS: fra+eng
      MAX_UPLOAD_MB: '20'
      CONVERT_TIMEOUT_S: '60'
    networks: [internal]
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://localhost:8000/health || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 1G

networks:
  traefik-public:
    external: true
  internal:
    driver: bridge
```

- [ ] **Step 3 : Supprimer fichiers obsolètes**

```bash
cd /Users/recarnot/dev/buck-writer-app
git rm deploy-vps/Caddyfile deploy-vps/.env.production deploy-vps/.env.trinity
```

- [ ] **Step 4 : Vérifier la syntaxe compose**

```bash
docker compose -f deploy-vps/compose.yml config > /dev/null
# Doit pas planter (les images n'existent pas encore mais la syntaxe est valide)
```

- [ ] **Step 5 : Commit**

```bash
git add deploy-vps/compose.yml
git commit -m "feat(deploy): rewrite compose.yml for Traefik labels + GHCR images"
```

### Task 2.3 : Supprimer `deploy-vps/deploy.sh` et l'ancien workflow

**Files :**
- Delete : `buck-writer-app/deploy-vps/deploy.sh`
- Delete : `buck-writer-app/.github/workflows/deploy-vps.yml`

- [ ] **Step 1 : Supprimer**

```bash
cd /Users/recarnot/dev/buck-writer-app
git rm deploy-vps/deploy.sh
git rm .github/workflows/deploy-vps.yml
```

- [ ] **Step 2 : Commit**

```bash
git commit -m "chore(deploy): remove legacy deploy.sh + deploy-vps.yml workflow"
```

### Task 2.4 : Créer `.github/workflows/release.yml`

**Files :**
- Create : `buck-writer-app/.github/workflows/release.yml`

- [ ] **Step 1 : Écrire le workflow**

```yaml
# buck-writer-app/.github/workflows/release.yml
name: release
on:
  push:
    tags: ['buck-v*']

jobs:
  build-push:
    name: Build and push ${{ matrix.image.name }}
    runs-on: ubuntu-latest
    timeout-minutes: 30
    permissions:
      contents: read
      packages: write
    strategy:
      fail-fast: false
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
        # buck-v1.2.3 → v1.2.3

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
    name: Trigger deploy on infra repo
    needs: build-push
    runs-on: ubuntu-latest
    steps:
      - uses: peter-evans/repository-dispatch@v3
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

- [ ] **Step 2 : Commit**

```bash
cd /Users/recarnot/dev/buck-writer-app
git add .github/workflows/release.yml
git commit -m "feat(ci): add release workflow (build/push GHCR + dispatch infra)"
```

### Task 2.5 : Configurer le PAT `INFRA_DISPATCH_PAT` du repo Buck

**Files :** aucun, conf GitHub.

- [ ] **Step 1 : Créer un fine-grained PAT**

Aller sur `https://github.com/settings/personal-access-tokens/new` :
- Resource owner : `eRom`
- Repository access : "Selected" → `vps-docker-manager-prod`
- Permissions : "Contents" = **Read and write** (nécessaire pour `repository_dispatch`)
- Expiration : 1 an

Copier le PAT généré.

- [ ] **Step 2 : Ajouter comme secret du repo Buck**

Aller sur `https://github.com/eRom/buck-writer-app/settings/secrets/actions` → "New repository secret" → name=`INFRA_DISPATCH_PAT`, value=le PAT.

- [ ] **Step 3 : Vérifier**

```bash
gh secret list --repo eRom/buck-writer-app
# Doit contenir INFRA_DISPATCH_PAT
```

### Task 2.6 : Push toutes les modifications Buck

- [ ] **Step 1 : Push**

```bash
cd /Users/recarnot/dev/buck-writer-app
git push origin main
```

(À ce stade, AUCUN deploy ne se déclenche : on n'a pas tagué.)

### Task 2.7 : Push toutes les modifications repo prod

- [ ] **Step 1 : Push**

```bash
cd /Users/recarnot/dev/vps-docker-manager-prod
git push origin main
```

---

## Phase 3 — Préparer le VPS et exécuter le premier deploy

**But :** Préparer le VPS (restauration data, cron, reboot kernel), puis taguer une release-candidate et valider tout le pipeline end-to-end.

### Task 3.1 : Préparer `/opt/buck/` sur le VPS et restaurer le snapshot data

**Files :** opérations sur le VPS, pas de fichiers repo.

- [ ] **Step 1 : Vérifier la présence du snapshot localement**

```bash
ls -la ~/Backups/vps-pre-migration/snapshot-20260425-122029.tgz
```

- [ ] **Step 2 : Inspecter la structure du tarball pour ajuster `--strip-components`**

```bash
tar tzf ~/Backups/vps-pre-migration/snapshot-20260425-122029.tgz | head -20
# Repérer le préfixe (probablement "opt/buck-writer-app/data/...") pour ajuster N
```

- [ ] **Step 3 : Créer l'arborescence VPS**

```bash
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 \
  "mkdir -p /opt/buck/{data/db,data/workspace,data/bible,deploy-vps}"
```

- [ ] **Step 4 : Copier le snapshot sur le VPS**

```bash
scp -i ~/.ssh/id_vps20260131 \
  ~/Backups/vps-pre-migration/snapshot-20260425-122029.tgz \
  root@72.62.239.98:/tmp/snapshot.tgz
```

- [ ] **Step 5 : Extraire au bon endroit (ajuster N selon Step 2)**

```bash
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 bash <<'EOF'
  set -euo pipefail
  cd /opt/buck
  # Si tarball commence par "opt/buck-writer-app/data/" → strip 3
  # Si commence par "data/" → strip 0
  # Ajuster la valeur ci-dessous après inspection :
  STRIP=3
  tar xzf /tmp/snapshot.tgz --strip-components=$STRIP
  ls -la data/
EOF
```

- [ ] **Step 6 : Fixer les permissions (gotcha UID 1000 connu)**

```bash
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 \
  "chown -R 1000:1000 /opt/buck/data && ls -la /opt/buck/data/"
```

- [ ] **Step 7 : Nettoyer le snapshot temporaire**

```bash
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 "rm /tmp/snapshot.tgz"
```

### Task 3.2 : Configurer le cron backup

**Files :** sur le VPS.

- [ ] **Step 1 : Copier le script depuis le repo prod cloné sur le VPS**

```bash
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 bash <<'EOF'
  set -euo pipefail
  cd /opt/_infra
  git pull origin main
  mkdir -p /opt/_infra/backups/buck
  ls scripts/
EOF
```

- [ ] **Step 2 : Tester le script à blanc**

```bash
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 \
  "/opt/_infra/scripts/backup-buck.sh buck"
# Doit créer des fichiers dans /opt/_infra/backups/buck/
```

- [ ] **Step 3 : Installer le cron**

```bash
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 bash <<'EOF'
  cat > /etc/cron.d/backup-buck <<'CRON'
# Backup quotidien Buck à 03:30 (juste après acme.json à 03:00)
30 3 * * * root /opt/_infra/scripts/backup-buck.sh buck >> /var/log/backup-buck.log 2>&1
CRON
  chmod 644 /etc/cron.d/backup-buck
  systemctl reload cron
EOF
```

- [ ] **Step 4 : Vérifier que cron a chargé**

```bash
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 \
  "cat /etc/cron.d/backup-buck && systemctl status cron --no-pager | head -10"
```

### Task 3.3 : Reboot du VPS pour appliquer le kernel update

**Files :** aucun.

⚠️ **Cette étape coupera Traefik et Uptime Kuma quelques minutes.** Prévenir Romain avant de l'exécuter.

- [ ] **Step 1 : Vérifier qu'aucun deploy n'est en cours**

```bash
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 "uptime && uname -r"
```

- [ ] **Step 2 : Reboot**

```bash
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 "reboot" || true
# La connexion se coupe (normal)
```

- [ ] **Step 3 : Attendre + vérifier que Traefik est de nouveau up**

```bash
sleep 90
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 "uname -r && uptime && docker ps"
# Le kernel doit avoir changé (plus de "*** System restart required ***")
# Traefik et Uptime Kuma doivent tourner
```

- [ ] **Step 4 : Vérifier Traefik HTTPS**

```bash
curl -sI https://traefik.apps.romain-ecarnot.com | head -3
# 401 attendu (basicauth, mais signe que Traefik répond)
```

### Task 3.4 : Premier deploy — tag `buck-v1.0.0-rc.1`

**Files :** aucun, juste un tag git.

- [ ] **Step 1 : Vérifier que tout est push (Buck + repo prod)**

```bash
cd /Users/recarnot/dev/buck-writer-app && git status && git log --oneline -3
cd /Users/recarnot/dev/vps-docker-manager-prod && git status && git log --oneline -3
```

- [ ] **Step 2 : Tag + push**

```bash
cd /Users/recarnot/dev/buck-writer-app
git tag buck-v1.0.0-rc.1 -m "First Buck deploy on new pattern (Traefik + GHCR + sops)"
git push origin buck-v1.0.0-rc.1
```

- [ ] **Step 3 : Suivre le workflow `release.yml`**

```bash
gh run watch --repo eRom/buck-writer-app
# Attendre que les 5 builds + le dispatch soient verts (~6-10 min première fois)
```

- [ ] **Step 4 : Suivre le workflow `deploy.yml` côté infra**

```bash
gh run watch --repo eRom/vps-docker-manager-prod
# Doit déclencher automatiquement après le dispatch
# Attendre que ce soit vert (~3-5 min)
```

- [ ] **Step 5 : Vérifier que `apps/buck/deploy-state.yaml` a été commit auto**

```bash
cd /Users/recarnot/dev/vps-docker-manager-prod
git pull origin main
cat apps/buck/deploy-state.yaml
# Doit montrer tag=buck-v1.0.0-rc.1, sha=..., deployed_at=...
git log --oneline -3
# Doit montrer un commit "deploy: buck buck-v1.0.0-rc.1"
```

- [ ] **Step 6 : Vérifier les containers sur le VPS**

```bash
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 \
  "cd /opt/buck/deploy-vps && docker compose --env-file /opt/buck/.env ps"
# Doit lister 5 containers tous "running"
```

- [ ] **Step 7 : Vérifier la notif Telegram**

Vérifier que le message `✅ Deploy buck buck-v1.0.0-rc.1 OK` est bien arrivé sur Telegram.

### Task 3.5 : Vérifications fonctionnelles manuelles (Romain)

**Files :** aucun, tests manuels via navigateur/curl.

- [ ] **Step 1 : Healthcheck Buck**

```bash
curl -sI https://buck.apps.romain-ecarnot.com/api/health
# HTTP 200 attendu
```

- [ ] **Step 2 : Connexion magic-link Buck**

Aller sur `https://buck.apps.romain-ecarnot.com`, demander un magic-link, recevoir l'email, se connecter. Vérifier que la session marche.

- [ ] **Step 3 : Bible UI (forward_auth Traefik)**

Ouvrir `https://bible.buck.apps.romain-ecarnot.com` :
- Sans session Buck → 401 ou redirect (forward_auth refuse)
- Avec session Buck active dans un autre onglet → 200, UI Bible accessible

- [ ] **Step 4 : MCP Bearer auth (bible-mcp)**

```bash
# Sans Bearer → 401
curl -sI https://bible-mcp.buck.apps.romain-ecarnot.com/mcp

# Avec Bearer (récupérer MCP_SHARED_SECRET depuis 1Password ou sops -d)
SECRET=$(sops -d /Users/recarnot/dev/vps-docker-manager-prod/secrets/buck.enc.yaml | yq '.MCP_SHARED_SECRET')
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}'
curl -s -X POST \
  -H "Authorization: Bearer $SECRET" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d "$INIT" \
  https://bible-mcp.buck.apps.romain-ecarnot.com/mcp | head -c 200
# Doit retourner du JSON MCP, pas du HTML 401
```

- [ ] **Step 5 : Génération avec MCP call**

Dans Buck, créer un projet, écrire un prompt qui force un MCP call (ex: "cherche dans ma bible le terme X"). Vérifier que ça répond et qu'on voit l'appel dans les logs `bible-mcp`.

- [ ] **Step 6 : Upload .docx (markitdown-worker)**

Dans Buck, uploader un .docx. Vérifier que le contenu est extrait (donc markitdown-worker tourne).

- [ ] **Step 7 : Si tout OK → mention dans Gerber**

```bash
# (à faire manuellement via /gerber:capture ou MCP)
```

### Task 3.6 : Tag `buck-v1.0.0` officiel (si stabilité 24h+)

⏳ **Attendre 24-48h** d'usage en condition réelle avant cette étape.

- [ ] **Step 1 : Surveiller logs et stabilité**

```bash
# Skill /deploy:status buck (livrée en Phase 4) ou directement :
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 \
  "cd /opt/buck/deploy-vps && docker compose --env-file /opt/buck/.env logs --tail 50"
```

- [ ] **Step 2 : Tag officiel**

```bash
cd /Users/recarnot/dev/buck-writer-app
git tag buck-v1.0.0 -m "Buck stable on new VPS pattern"
git push origin buck-v1.0.0
```

- [ ] **Step 3 : Re-suivre le pipeline (mêmes vérifs que Task 3.4)**

---

## Phase 4 — Tooling Claude

**But :** Livrer les 4 skills `/deploy:*` + le sub-agent `deploy-doctor` dans `vps-docker-manager-prod/.claude/`.

### Task 4.1 : Skill `/deploy:status`

**Files :**
- Create : `vps-docker-manager-prod/.claude/skills/deploy/status.md`

- [ ] **Step 1 : Créer le dossier et le fichier**

```bash
mkdir -p /Users/recarnot/dev/vps-docker-manager-prod/.claude/skills/deploy
```

```markdown
---
name: deploy:status
description: Snapshot de l'état d'une app (ou de toutes) déployée sur le VPS. Lecture pure (jamais d'écriture). Utilise /deploy:status pour voir ce qui tourne. Optionnel : nom d'app (buck, n8n, trinity) ; sans arg, liste toutes les apps.
---

# /deploy:status [app]

## Workflow

1. Lire `apps/*/deploy-state.yaml` pour récupérer la liste des apps + tag courant.
2. Pour chaque app (ou celle passée en arg) :
   - SSH VPS : `cd /opt/${APP}/deploy-vps && docker compose --env-file /opt/${APP}/.env ps --format json`
   - Curl healthcheck : `https://${APP}.apps.romain-ecarnot.com/api/health` (timeout 5s)
3. Formater en Markdown :
   - Header par app : nom, tag courant (depuis deploy-state), date dernier deploy
   - Tableau containers : Service | Status | Image | Health
   - Healthcheck HTTPS : 200/non-200/timeout
4. Si tous les containers OK et healthcheck 200 → 🟢. Sinon → 🟡 ou 🔴.

## Implémentation

```bash
#!/usr/bin/env bash
set -euo pipefail

APP="${1:-}"
VPS_KEY="$HOME/.ssh/id_vps20260131"
VPS_HOST="root@72.62.239.98"

list_apps() {
  if [ -n "$APP" ]; then
    echo "$APP"
  else
    ls -1 apps/ 2>/dev/null
  fi
}

for app in $(list_apps); do
  state_file="apps/$app/deploy-state.yaml"
  [ -f "$state_file" ] || continue

  tag=$(yq '.tag' "$state_file")
  deployed_at=$(yq '.deployed_at' "$state_file")

  echo "## $app — $tag (deployed $deployed_at)"
  echo ""
  ssh -i "$VPS_KEY" "$VPS_HOST" \
    "cd /opt/$app/deploy-vps && docker compose --env-file /opt/$app/.env ps --format 'table {{.Service}}\t{{.Status}}\t{{.Image}}'" \
    2>/dev/null || echo "  ⚠️  SSH or compose error"
  echo ""

  health_url="https://${app}.apps.romain-ecarnot.com/api/health"
  code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 5 "$health_url" || echo "000")
  if [ "$code" = "200" ]; then
    echo "🟢 Healthcheck $health_url → 200"
  else
    echo "🔴 Healthcheck $health_url → $code"
  fi
  echo "---"
done
```

## Restrictions

- Lecture pure, jamais de modification.
- Ne lance aucun deploy ni rollback.
- Ne touche jamais aux secrets sops (pas de `sops -d`).
```

- [ ] **Step 2 : Commit**

```bash
cd /Users/recarnot/dev/vps-docker-manager-prod
git add .claude/skills/deploy/status.md
git commit -m "feat(skills): add /deploy:status (read-only snapshot)"
```

### Task 4.2 : Skill `/deploy:logs`

**Files :**
- Create : `vps-docker-manager-prod/.claude/skills/deploy/logs.md`

- [ ] **Step 1 : Créer la skill**

```markdown
---
name: deploy:logs
description: Tail des logs d'une app déployée sur le VPS, optionnellement filtrés par service et fenêtre temporelle. Usage : /deploy:logs <app> [--since 10m] [--service <name>]. Toujours sur lecture seule.
---

# /deploy:logs <app> [--since 10m] [--service <name>]

## Workflow

1. Parser les args (app obligatoire, --since et --service optionnels).
2. SSH VPS : `cd /opt/${APP}/deploy-vps && docker compose --env-file /opt/${APP}/.env logs --tail=200 ${SINCE:+--since $SINCE} $SERVICE`
3. Stream la sortie (pas de pipe à more).

## Implémentation

```bash
#!/usr/bin/env bash
set -euo pipefail

APP=""
SINCE=""
SERVICE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --since) SINCE="$2"; shift 2 ;;
    --service) SERVICE="$2"; shift 2 ;;
    *) APP="$1"; shift ;;
  esac
done

[ -n "$APP" ] || { echo "Usage: /deploy:logs <app> [--since 10m] [--service <name>]"; exit 1; }

VPS_KEY="$HOME/.ssh/id_vps20260131"
VPS_HOST="root@72.62.239.98"

CMD="cd /opt/$APP/deploy-vps && docker compose --env-file /opt/$APP/.env logs --tail=200"
[ -n "$SINCE" ] && CMD="$CMD --since $SINCE"
[ -n "$SERVICE" ] && CMD="$CMD $SERVICE"

ssh -i "$VPS_KEY" "$VPS_HOST" "$CMD"
```
```

- [ ] **Step 2 : Commit**

```bash
git add .claude/skills/deploy/logs.md
git commit -m "feat(skills): add /deploy:logs"
```

### Task 4.3 : Skill `/deploy:rollback`

**Files :**
- Create : `vps-docker-manager-prod/.claude/skills/deploy/rollback.md`

- [ ] **Step 1 : Créer la skill**

```markdown
---
name: deploy:rollback
description: Déclenche le rollback d'une app vers un tag précédent via le workflow GA (chemin A) avec résolution auto du SHA. Demande confirmation avant action. Usage : /deploy:rollback <app> <tag> (ex: /deploy:rollback buck buck-v1.0.0).
---

# /deploy:rollback <app> <tag>

## Workflow

1. Lire `apps/<app>/deploy-state.yaml` pour récupérer le tag courant et `app_repo`.
2. Résoudre le SHA du tag cible : `gh release view "<tag>" --repo <app_repo> --json targetCommitish`.
3. Afficher récap au user :
   - App
   - Tag courant → tag cible
   - SHA cible
   - Repo app
4. Demander confirmation explicite ("y" pour continuer).
5. Si y : `gh workflow run deploy.yml --repo eRom/vps-docker-manager-prod -f app=$APP -f app_repo=$APP_REPO -f tag=$TAG -f deploy_vps_ref=$SHA`.
6. Tail le run avec `gh run watch --repo eRom/vps-docker-manager-prod`.
7. Reporter succès/échec à l'utilisateur.

## Fallback parachute (si user dit "use SSH" ou si gh fail)

`ssh root@vps "/opt/_infra/scripts/rollback.sh <app> <tag>"` puis afficher le rappel "pense à committer deploy-state.yaml".

## Restrictions

- Toujours demander confirmation avant l'action.
- Ne jamais re-build d'images (utilise les images GHCR existantes).
- Si le tag demandé n'a plus d'image GHCR (purgée par retention), abort avec message explicite.
```

- [ ] **Step 2 : Commit**

```bash
git add .claude/skills/deploy/rollback.md
git commit -m "feat(skills): add /deploy:rollback (GA-driven with SSH fallback)"
```

### Task 4.4 : Skill `/deploy:bootstrap`

**Files :**
- Create : `vps-docker-manager-prod/.claude/skills/deploy/bootstrap.md`

- [ ] **Step 1 : Créer la skill**

```markdown
---
name: deploy:bootstrap
description: Onboarde une nouvelle app dans le pattern deploy-vps. Crée les fichiers côté repo prod (apps/<app>/, secrets/<app>.enc.yaml template) et génère un squelette deploy-vps/ + workflow release.yml dans le repo app. Workflow interactif. Usage : /deploy:bootstrap <app>.
---

# /deploy:bootstrap <app>

## Workflow

### 1. Collecter les infos via questions interactives

- `app_repo` : owner/name du repo app (ex: `eRom/n8n-stack`)
- `domain` : domaine principal (ex: `n8n.apps.romain-ecarnot.com`)
- `services` : liste des services (ex: `n8n`, `postgres`)
- `subdomains` : sous-domaines additionnels (ex: pour n8n : aucun ; pour Buck : bible, bible-mcp, writing-mcp)

### 2. Créer dans `vps-docker-manager-prod`

```bash
APP="$1"
mkdir -p apps/$APP

# deploy-state.yaml vide
cat > apps/$APP/deploy-state.yaml <<EOF
app: $APP
app_repo: $APP_REPO
tag: null
version: null
sha: null
deployed_at: null
deployed_by: null
EOF

# Template secrets sops (en clair pour édition immédiate par user)
cat > /tmp/$APP.yaml <<EOF
# === $APP secrets ===
# TODO: ajoute tes secrets ici, puis sauve.
EXAMPLE_KEY: replace_me
EOF
$EDITOR /tmp/$APP.yaml
sops -e /tmp/$APP.yaml > secrets/$APP.enc.yaml
shred -u /tmp/$APP.yaml
```

### 3. Mettre à jour `README.md` du repo prod (section "Apps")

Ajouter une ligne dans la table : `| $APP | $domain | (jamais déployé) | - |`.

### 4. Générer le squelette dans le repo app

Cloner le repo app (ou cd dedans), créer :
- `deploy-vps/compose.yml` (template avec labels Traefik génériques, à compléter par user pour les services)
- `deploy-vps/Dockerfile.app` (placeholder)
- `.github/workflows/release.yml` (matrix GHCR + dispatch, à éditer pour la matrix d'images réelle)

### 5. Checklist post-bootstrap (à imprimer pour user)

- [ ] Ajouter `INFRA_DISPATCH_PAT` (PAT scoped vps-docker-manager-prod) dans Secrets du repo app
- [ ] Ajouter clé age du runner GA dans `.sops.yaml` du repo prod
- [ ] Créer DNS records Cloudflare pour les domaines
- [ ] Éditer `deploy-vps/compose.yml` pour les vrais services
- [ ] Éditer `.github/workflows/release.yml` pour la matrix d'images réelle
- [ ] Compléter `secrets/$APP.enc.yaml` avec les vraies valeurs
- [ ] Premier tag : `git tag $APP-v0.1.0-rc.1 && git push --tags`

## Restrictions

- Si `apps/$APP/` existe déjà → demander confirmation overwrite.
- Ne jamais committer auto le secret en clair.
```

- [ ] **Step 2 : Commit**

```bash
git add .claude/skills/deploy/bootstrap.md
git commit -m "feat(skills): add /deploy:bootstrap (onboarding new apps)"
```

### Task 4.5 : Sub-agent `deploy-doctor`

**Files :**
- Create : `vps-docker-manager-prod/.claude/agents/deploy-doctor.md`

- [ ] **Step 1 : Créer le dossier + fichier**

```bash
mkdir -p /Users/recarnot/dev/vps-docker-manager-prod/.claude/agents
```

```markdown
---
name: deploy-doctor
description: Agent diagnostique pour une app déployée. Utilise cet agent quand un healthcheck échoue, qu'une app retourne 5xx, ou pour comprendre un problème post-deploy. L'agent ne modifie jamais rien — il diagnostique et propose des commandes. Usage : "Use deploy-doctor to investigate why buck is returning 502s".
tools: Bash, Read, WebFetch
---

# deploy-doctor

Tu es un agent diagnostique infra. Ton job : investiguer un problème sur une
app déployée et retourner un rapport hiérarchisé. **Tu n'écris rien, tu ne
modifies rien.** Tu lis, tu probes, tu raisonnes, tu proposes.

## Workflow standard

1. **Lire l'état déclaré** :
   - `apps/<app>/deploy-state.yaml` → tag courant, SHA, timestamp dernier deploy
   - `git log apps/<app>/deploy-state.yaml -3` → historique récent

2. **Inspecter le runtime VPS** :
   - SSH `root@72.62.239.98` (clé `~/.ssh/id_vps20260131`)
   - `cd /opt/<app>/deploy-vps && docker compose --env-file /opt/<app>/.env ps`
   - Pour chaque service en mauvais état : `docker logs <container> --tail 100`
   - `docker stats --no-stream` (CPU/RAM)

3. **Probe les endpoints publics** :
   - `curl -sI https://<app>.apps.romain-ecarnot.com/api/health` (et autres URLs documentées)
   - Comparer avec les logs Traefik : `docker logs traefik --since 10m | grep <app>`

4. **Comparer avec le précédent deploy** :
   - Si problème apparu juste après deploy : `git diff <previous_sha> <current_sha>` côté repo app pour suspecter un changement

5. **Synthétiser** :
   - Verdict : `🟢 HEALTHY | 🟡 DEGRADED | 🔴 DOWN`
   - Cause probable + niveau de confiance (faible/moyen/élevé)
   - 3 hypothèses ordonnées par probabilité, avec preuves
   - Commandes suggérées (jamais exécutées) :
     - Pour vérifier l'hypothèse
     - Pour mitiger (rollback, restart, edit secret + redeploy...)

## Format de sortie

```markdown
## Diagnostic <app> (<timestamp>)

**Verdict** : 🔴 DOWN

**Cause probable** : <X> (confiance moyenne)

**Hypothèses** :
1. <H1> — preuves : <logs/metrics>
2. <H2> — preuves : ...
3. <H3> — preuves : ...

**Commandes suggérées** :
- Pour vérifier H1 : `<cmd>`
- Pour mitiger : `<cmd>`

**Contexte récent** :
- Dernier deploy : <tag> @ <timestamp>
- Diff vs précédent : <résumé>
```

## Garde-fous

- **Aucun outil d'écriture** (pas de Edit/Write).
- **Jamais de `docker stop`/`restart`/`down`/`up`** dans les commandes que TU exécutes.
- Tu peux les **suggérer** dans la section "Commandes suggérées".
- Si tu détectes un secret en clair dans une sortie de log, NE PAS le re-mentionner dans le rapport (juste signaler "secret leak detected, voir log brut").
```

- [ ] **Step 2 : Commit**

```bash
cd /Users/recarnot/dev/vps-docker-manager-prod
git add .claude/agents/deploy-doctor.md
git commit -m "feat(agents): add deploy-doctor (read-only diagnostic agent)"
```

### Task 4.6 : Smoke test des 4 skills + agent

- [ ] **Step 1 : Test `/deploy:status`**

Dans une nouvelle session Claude Code dans `vps-docker-manager-prod/`, lancer `/deploy:status buck`. Vérifier que ça retourne un snapshot lisible.

- [ ] **Step 2 : Test `/deploy:logs buck --since 5m`**

Vérifier que le tail logs marche.

- [ ] **Step 3 : Test `/deploy:bootstrap testapp`**

Lancer en mode dry-run mental, ne pas valider la création réelle. Juste vérifier que le workflow interactif est cohérent. Annuler à la fin.

- [ ] **Step 4 : Test `/deploy:rollback buck buck-v1.0.0-rc.1`**

⚠️ Si déjà sur ce tag, ce sera un no-op. Si sur `v1.0.0`, ça redescend en `rc.1` (puis re-monter avec un `/deploy:rollback buck buck-v1.0.0`).

- [ ] **Step 5 : Test `deploy-doctor`**

Demander : "Use the deploy-doctor agent to give me a report on buck health."
Vérifier que le rapport est structuré, qu'il ne tente pas de modifier quoi que ce soit.

### Task 4.7 : Push tooling

- [ ] **Step 1 : Push**

```bash
cd /Users/recarnot/dev/vps-docker-manager-prod
git push origin main
```

---

## Phase 5 — Finalisation

### Task 5.1 : Mettre à jour le `README.md` du repo prod (dashboard)

**Files :**
- Modify : `vps-docker-manager-prod/README.md`

- [ ] **Step 1 : Ajouter une section "Apps déployées"**

```markdown
## Apps déployées

| App | Domaine | Tag courant | Dernier deploy |
|---|---|---|---|
| buck | https://buck.apps.romain-ecarnot.com | (cf `apps/buck/deploy-state.yaml`) | (auto) |

(table mise à jour à la main pour l'instant ; un script pourra l'auto-générer plus tard à partir des `deploy-state.yaml`)
```

- [ ] **Step 2 : Commit**

```bash
cd /Users/recarnot/dev/vps-docker-manager-prod
git add README.md
git commit -m "docs(readme): add deployed apps dashboard section"
```

### Task 5.2 : Écrire `docs/lessons-buck-onboarding.md`

**Files :**
- Create : `vps-docker-manager-prod/docs/lessons-buck-onboarding.md`

- [ ] **Step 1 : Squelette à compléter par Romain après stabilité v1.0.0**

```markdown
# Lessons learned — Buck onboarding (2026-04-XX)

## Ce qui a marché
- ...

## Ce qui a frotté
- ...

## Ajustements pour le prochain onboarding (n8n, trinity)
- [ ] ...
- [ ] ...

## Modifications à porter sur les skills/templates
- [ ] ...
```

- [ ] **Step 2 : Commit**

```bash
git add docs/lessons-buck-onboarding.md
git commit -m "docs: add lessons-buck-onboarding skeleton (to fill post-v1)"
```

### Task 5.3 : Push final + tag baseline du repo prod

- [ ] **Step 1 : Push**

```bash
cd /Users/recarnot/dev/vps-docker-manager-prod
git push origin main
```

- [ ] **Step 2 : Tag du repo prod baseline (optionnel mais utile)**

```bash
git tag v0.2.0 -m "Buck deploy migration done; multi-app pattern live"
git push origin v0.2.0
```

---

## Critères d'acceptation finaux (cf spec §8)

À cocher une fois la migration validée bout en bout :

- [ ] Tag `buck-v1.0.0` déclenche le pipeline complet sans intervention manuelle.
- [ ] Les 5 images Buck sont push sur GHCR sous `ghcr.io/erom/buck-*:v1.0.0`.
- [ ] `apps/buck/deploy-state.yaml` est commit auto sur `main` du repo infra prod.
- [ ] Les 5 containers tournent sur le VPS, accessibles via les domaines `*.apps.romain-ecarnot.com`.
- [ ] Healthcheck `https://buck.apps.romain-ecarnot.com/api/health` retourne 200.
- [ ] Forward_auth Bible UI fonctionne.
- [ ] Bearer auth MCP fonctionne (401 sans, 200 avec).
- [ ] Notif Telegram reçue.
- [ ] Aucun build n'a tourné sur le VPS.
- [ ] `/deploy:status buck` retourne un snapshot lisible.
- [ ] `/deploy:rollback` testé et fonctionnel.
- [ ] Cron backup tourne à 03:30.
- [ ] Le repo Trinity n'est pas touché par le deploy Buck.

---

## Notes pour l'engineer qui exécute ce plan

- **Ordre strict** : Phases 1 → 2 → 3 → 4 → 5. La Phase 3 dépend de la 1 (secrets/scripts/workflow) et de la 2 (compose réécrit + workflow release).
- **Phase 4 peut être exécutée en parallèle de la 3** si tu veux gagner du temps, mais je recommande de la faire après pour pouvoir tester sur Buck déjà déployé.
- **Si la Task 3.4 échoue** (premier deploy), invoquer `deploy-doctor` (livré en Phase 4) ou lire les logs GA + VPS manuellement. Cause probable première fois : sops decrypt fail (mauvais recipient), ou tarball strip-components mal réglé, ou MCP_SHARED_SECRET pas substitué dans middleware Traefik.
- **Romain doit valider manuellement** la Task 3.5 (tests fonctionnels). Pas d'automation de ces vérifs UI.
- **Frequent commits** : chaque task = 1 ou 2 commits. Pas de gros commits monolithiques.
- **Pour les écritures secrets** : toujours `shred -u` le fichier clair après chiffrement, jamais juste `rm`.
