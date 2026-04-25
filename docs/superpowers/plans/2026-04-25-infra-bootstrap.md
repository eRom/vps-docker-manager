# `infra-bootstrap` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Poser sur le VPS Hostinger `72.62.239.98` une stack d'infrastructure partagée (Traefik v3 + ACME Cloudflare DNS-01 + secrets sops/age + Uptime Kuma) sur laquelle tous les futurs projets se brancheront via labels Docker, sans interrompre Trinity et Buck qui tournent en parallèle.

**Architecture:** Templates versionnés dans `vps-docker-manager/templates/infra-bootstrap/` (repo public). Instanciation dans `vps-docker-manager-prod` (repo privé GitHub) avec secrets chiffrés sops. Déploiement sur VPS dans `/opt/_infra/` via git pull + bootstrap script idempotent. Cutover applicatif différé au sous-projet `migration-trinity-buck`.

**Tech Stack:** Traefik v3.3, Docker Compose v2, sops 3.9.x, age 1.1.x, Cloudflare API (DNS challenge), Let's Encrypt (staging puis prod), Uptime Kuma 1.x, bash, Telegram Bot API (alerting).

**Spec source:** `docs/superpowers/specs/2026-04-25-infra-bootstrap-design.md`

---

## File structure (templates dans `vps-docker-manager`)

```
templates/infra-bootstrap/
├── README.md                          # mode d'emploi du template
├── .gitignore                         # data/, secrets.yaml clair
├── .sops.yaml                         # règles sops (placeholders pour clés age)
├── secrets.example.yaml               # template secrets en clair
├── docker-compose.yml                 # Traefik + Uptime Kuma
├── traefik/
│   ├── traefik.yml                    # config statique Traefik
│   └── dynamic/
│       ├── middlewares.yml            # security-headers, basicauth, rate-limit
│       └── tls.yml                    # TLS options globales
└── scripts/
    ├── bootstrap-vps.sh               # idempotent, exécuté sur le VPS
    ├── start.sh                       # decrypt sops + docker compose up
    ├── stop.sh                        # docker compose down
    └── backup-acme.sh                 # snapshot acme.json horodaté
```

**Conventions :**
- Tous les bash : `#!/usr/bin/env bash` + `set -euo pipefail`
- Indentation YAML : 2 espaces
- Pas de variables hardcodées dans les templates → `__PLACEHOLDER__` substitués à l'instanciation

---

## Phase 1 — Templates dans `vps-docker-manager` (repo public)

### Task 1 : Arborescence + .gitignore template

**Files:**
- Create: `templates/infra-bootstrap/.gitignore`
- Create: `templates/infra-bootstrap/README.md` (squelette, complété en Task 9)

- [ ] **Step 1 : Créer l'arborescence vide**

```bash
cd /Users/recarnot/dev/vps-docker-manager
mkdir -p templates/infra-bootstrap/{traefik/dynamic,scripts}
```

- [ ] **Step 2 : Écrire `.gitignore`**

Contenu de `templates/infra-bootstrap/.gitignore` :

```gitignore
# Secrets en clair — NE JAMAIS COMMITER
secrets.yaml
*.yaml.bak

# Volumes runtime
data/
!data/.gitkeep

# Clés age (privées)
keys.txt
age/

# OS
.DS_Store

# Dotenv générés à la volée
.env
.env.local
.env.traefik
```

- [ ] **Step 3 : Créer le placeholder data/.gitkeep**

```bash
mkdir -p templates/infra-bootstrap/data
touch templates/infra-bootstrap/data/.gitkeep
```

- [ ] **Step 4 : Écrire le squelette README.md**

Contenu minimal (sera enrichi en Task 9) :

```markdown
# Template `infra-bootstrap`

Squelette d'instanciation pour le repo privé `vps-docker-manager-prod`.
Documentation complète : voir Task 9 du plan.
```

- [ ] **Step 5 : Commit**

```bash
git add templates/infra-bootstrap/
git commit -m "feat(infra-bootstrap): scaffolding template"
```

---

### Task 2 : `traefik/traefik.yml` (config statique)

**Files:**
- Create: `templates/infra-bootstrap/traefik/traefik.yml`

- [ ] **Step 1 : Écrire le fichier**

Contenu de `templates/infra-bootstrap/traefik/traefik.yml` :

```yaml
global:
  checkNewVersion: false
  sendAnonymousUsage: false

log:
  level: INFO
  format: json

api:
  dashboard: true
  insecure: false

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
          permanent: true
  websecure:
    address: ":443"

providers:
  docker:
    exposedByDefault: false
    network: traefik-public
  file:
    directory: /dynamic
    watch: true

certificatesResolvers:
  acme-cloudflare:
    acme:
      email: romain@romain-ecarnot.com
      storage: /data/acme.json
      # === PREMIER BOOT : staging actif (limite haute, certs auto-signes navigateur) ===
      caServer: https://acme-staging-v02.api.letsencrypt.org/directory
      # === APRES VALIDATION : commenter le staging ci-dessus, decommenter prod ci-dessous,
      #     supprimer data/acme.json, redemarrer Traefik ===
      # caServer: https://acme-v02.api.letsencrypt.org/directory
      dnsChallenge:
        provider: cloudflare
        resolvers:
          - "1.1.1.1:53"
          - "8.8.8.8:53"
        delayBeforeCheck: 30
```

- [ ] **Step 2 : Valider la syntaxe YAML**

Run :

```bash
python3 -c "import yaml; yaml.safe_load(open('templates/infra-bootstrap/traefik/traefik.yml'))"
```

Expected : aucune sortie (= OK).

- [ ] **Step 3 : Commit**

```bash
git add templates/infra-bootstrap/traefik/traefik.yml
git commit -m "feat(infra-bootstrap): traefik static config (staging ACME by default)"
```

---

### Task 3 : Middlewares + TLS dynamiques

**Files:**
- Create: `templates/infra-bootstrap/traefik/dynamic/middlewares.yml`
- Create: `templates/infra-bootstrap/traefik/dynamic/tls.yml`

- [ ] **Step 1 : Écrire `middlewares.yml`**

```yaml
http:
  middlewares:
    # BasicAuth pour le dashboard Traefik.
    # Le fichier .htpasswd-dashboard est genere par start.sh depuis sops
    # (cle traefik.DASHBOARD_BASIC_AUTH au format "user:bcrypt-hash").
    dashboard-auth:
      basicAuth:
        usersFile: /dynamic/.htpasswd-dashboard

    # Headers securite par defaut, applicable a tout service via @file.
    security-headers:
      headers:
        frameDeny: true
        contentTypeNosniff: true
        browserXssFilter: true
        referrerPolicy: "strict-origin-when-cross-origin"
        stsSeconds: 31536000
        stsIncludeSubdomains: true
        stsPreload: true

    # Rate limit global a appliquer aux APIs sensibles via labels projet.
    api-ratelimit:
      rateLimit:
        average: 100
        burst: 50

    # Redirect www -> apex.
    redirect-www:
      redirectRegex:
        regex: "^https://www\\.(.+)"
        replacement: "https://${1}"
        permanent: true
```

- [ ] **Step 2 : Écrire `tls.yml`**

```yaml
tls:
  options:
    default:
      minVersion: VersionTLS12
      sniStrict: true
      cipherSuites:
        - TLS_AES_128_GCM_SHA256
        - TLS_AES_256_GCM_SHA384
        - TLS_CHACHA20_POLY1305_SHA256
        - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
        - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
```

- [ ] **Step 3 : Valider les YAML**

```bash
for f in templates/infra-bootstrap/traefik/dynamic/*.yml; do
  python3 -c "import yaml; yaml.safe_load(open('$f'))" && echo "OK $f"
done
```

Expected : `OK templates/infra-bootstrap/traefik/dynamic/middlewares.yml` puis `OK ...tls.yml`.

- [ ] **Step 4 : Commit**

```bash
git add templates/infra-bootstrap/traefik/dynamic/
git commit -m "feat(infra-bootstrap): traefik dynamic config (middlewares + tls)"
```

---

### Task 4 : `docker-compose.yml`

**Files:**
- Create: `templates/infra-bootstrap/docker-compose.yml`

- [ ] **Step 1 : Écrire le compose**

```yaml
networks:
  traefik-public:
    external: true        # cree par bootstrap-vps.sh
  infra-internal:
    internal: true

services:
  traefik:
    image: traefik:v3.3
    container_name: traefik
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    ports:
      - "80:80"
      - "443:443"
    environment:
      CF_DNS_API_TOKEN: ${CF_DNS_API_TOKEN}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik/traefik.yml:/traefik.yml:ro
      - ./traefik/dynamic:/dynamic:ro
      - ./data/acme.json:/data/acme.json
    networks:
      - traefik-public
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.dashboard.rule=Host(`traefik.apps.romain-ecarnot.com`)"
      - "traefik.http.routers.dashboard.entrypoints=websecure"
      - "traefik.http.routers.dashboard.tls.certresolver=acme-cloudflare"
      - "traefik.http.routers.dashboard.tls.domains[0].main=apps.romain-ecarnot.com"
      - "traefik.http.routers.dashboard.tls.domains[0].sans=*.apps.romain-ecarnot.com"
      - "traefik.http.routers.dashboard.service=api@internal"
      - "traefik.http.routers.dashboard.middlewares=dashboard-auth@file,security-headers@file"

  uptime-kuma:
    image: louislam/uptime-kuma:1
    container_name: uptime-kuma
    restart: unless-stopped
    volumes:
      - ./data/uptime-kuma:/app/data
    networks:
      - traefik-public
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.status.rule=Host(`status.apps.romain-ecarnot.com`)"
      - "traefik.http.routers.status.entrypoints=websecure"
      - "traefik.http.routers.status.tls.certresolver=acme-cloudflare"
      - "traefik.http.routers.status.middlewares=security-headers@file"
      - "traefik.http.services.status.loadbalancer.server.port=3001"
```

- [ ] **Step 2 : Valider la syntaxe Compose**

Run :

```bash
docker compose -f templates/infra-bootstrap/docker-compose.yml config --quiet
```

Expected : aucune sortie (= OK). Si erreur "external network not found", c'est normal en local — on peut ignorer cette erreur précise et vérifier avec :

```bash
docker compose -f templates/infra-bootstrap/docker-compose.yml config 2>&1 | grep -v "network traefik-public" | head -20
```

Expected : pas d'erreur de syntaxe YAML, juste l'avertissement réseau.

- [ ] **Step 3 : Commit**

```bash
git add templates/infra-bootstrap/docker-compose.yml
git commit -m "feat(infra-bootstrap): docker-compose with traefik + uptime-kuma"
```

---

### Task 5 : `.sops.yaml` + `secrets.example.yaml`

**Files:**
- Create: `templates/infra-bootstrap/.sops.yaml`
- Create: `templates/infra-bootstrap/secrets.example.yaml`

- [ ] **Step 1 : Écrire `.sops.yaml` (placeholders)**

```yaml
# Regles sops pour ce projet.
# Remplacer les __AGE_PUBKEY_*__ par les vraies cles age publiques.
# Au minimum 2 cles : laptop (developpeur) + VPS (runtime).
creation_rules:
  - path_regex: secrets\.enc\.yaml$
    age:
      - __AGE_PUBKEY_LAPTOP__
      - __AGE_PUBKEY_VPS__
  - path_regex: \.env\.enc$
    age:
      - __AGE_PUBKEY_LAPTOP__
      - __AGE_PUBKEY_VPS__
```

- [ ] **Step 2 : Écrire `secrets.example.yaml`**

```yaml
# Template des secrets attendus par la stack _infra.
# Procedure d'instanciation :
#   1. cp secrets.example.yaml secrets.yaml
#   2. Remplir avec les vraies valeurs
#   3. sops --encrypt secrets.yaml > secrets.enc.yaml
#   4. rm secrets.yaml
#   5. git add secrets.enc.yaml && git commit

cloudflare:
  # Token API scoped Zone:DNS:Edit + Zone:Zone:Read sur romain-ecarnot.com
  CF_DNS_API_TOKEN: "REPLACE_WITH_CLOUDFLARE_TOKEN"
  # ID de la zone romain-ecarnot.com (recuperable via curl, voir README)
  CF_ZONE_ID: "REPLACE_WITH_ZONE_ID"

traefik:
  # Format htpasswd bcrypt natif (UN SEUL $, pas de doublage : on l'ecrit dans un
  # fichier .htpasswd lu par Traefik, pas dans une env var Compose).
  # Generation : htpasswd -nBb admin "MonMotDePasse"
  DASHBOARD_BASIC_AUTH: "admin:$2y$05$REPLACE_WITH_BCRYPT_HASH"

uptime_kuma:
  # Bot Telegram pour les alertes (creer via @BotFather)
  TELEGRAM_BOT_TOKEN: "REPLACE_WITH_BOT_TOKEN"
  # Chat ID destination (recuperable via /start sur le bot)
  TELEGRAM_CHAT_ID: "REPLACE_WITH_CHAT_ID"
```

- [ ] **Step 3 : Valider YAML**

```bash
python3 -c "import yaml; yaml.safe_load(open('templates/infra-bootstrap/.sops.yaml'))"
python3 -c "import yaml; yaml.safe_load(open('templates/infra-bootstrap/secrets.example.yaml'))"
```

Expected : aucune sortie pour chaque commande.

- [ ] **Step 4 : Commit**

```bash
git add templates/infra-bootstrap/.sops.yaml templates/infra-bootstrap/secrets.example.yaml
git commit -m "feat(infra-bootstrap): sops config + secrets template"
```

---

### Task 6 : `scripts/bootstrap-vps.sh`

**Files:**
- Create: `templates/infra-bootstrap/scripts/bootstrap-vps.sh`

- [ ] **Step 1 : Écrire le script**

```bash
#!/usr/bin/env bash
# bootstrap-vps.sh — Idempotent. Execute sur le VPS via SSH.
# Premier run : installe sops/age si manquants, cree la cle age VPS, s'arrete.
# Runs suivants : verifie l'etat, cree le reseau et acme.json si manquants.

set -euo pipefail

readonly SOPS_VERSION="v3.9.4"
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
```

- [ ] **Step 2 : Rendre exécutable**

```bash
chmod +x templates/infra-bootstrap/scripts/bootstrap-vps.sh
```

- [ ] **Step 3 : Valider syntaxe bash**

```bash
bash -n templates/infra-bootstrap/scripts/bootstrap-vps.sh && echo "OK"
```

Expected : `OK`.

- [ ] **Step 4 : Lint avec shellcheck (si installé)**

```bash
command -v shellcheck >/dev/null && \
  shellcheck templates/infra-bootstrap/scripts/bootstrap-vps.sh || \
  echo "shellcheck non installe, skip (brew install shellcheck pour activer)"
```

Expected : aucune erreur, ou message "non installe".

- [ ] **Step 5 : Commit**

```bash
git add templates/infra-bootstrap/scripts/bootstrap-vps.sh
git commit -m "feat(infra-bootstrap): idempotent bootstrap script"
```

---

### Task 7 : `scripts/start.sh` + `stop.sh` + `backup-acme.sh`

**Files:**
- Create: `templates/infra-bootstrap/scripts/start.sh`
- Create: `templates/infra-bootstrap/scripts/stop.sh`
- Create: `templates/infra-bootstrap/scripts/backup-acme.sh`

- [ ] **Step 1 : Écrire `start.sh`**

```bash
#!/usr/bin/env bash
# start.sh — Decrypte les secrets, genere le htpasswd dashboard, demarre Traefik+Uptime Kuma.

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly INFRA_DIR="$(dirname "${SCRIPT_DIR}")"
readonly SECRETS_FILE="${INFRA_DIR}/secrets.enc.yaml"
readonly HTPASSWD_FILE="${INFRA_DIR}/traefik/dynamic/.htpasswd-dashboard"

log() { echo "[start] $*"; }

cd "${INFRA_DIR}"

if [ ! -f "${SECRETS_FILE}" ]; then
  echo "Erreur : ${SECRETS_FILE} introuvable." >&2
  exit 1
fi

log "Dechiffrement des secrets..."
export CF_DNS_API_TOKEN="$(sops -d --extract '["cloudflare"]["CF_DNS_API_TOKEN"]' "${SECRETS_FILE}")"

log "Generation .htpasswd-dashboard..."
DASHBOARD_AUTH="$(sops -d --extract '["traefik"]["DASHBOARD_BASIC_AUTH"]' "${SECRETS_FILE}")"
# Le format stocke est "user:$2y$..." — on l'ecrit tel quel (htpasswd-style),
# en re-doublant les $ supprimes par sops si besoin (ici on prend la valeur brute).
echo "${DASHBOARD_AUTH}" > "${HTPASSWD_FILE}"
chmod 600 "${HTPASSWD_FILE}"

log "Demarrage docker compose..."
docker compose up -d

log "Attente 5s puis affichage des logs Traefik..."
sleep 5
docker compose logs --tail=30 traefik

log "Stack demarree. Verifications :"
echo "  - Dashboard : https://traefik.apps.romain-ecarnot.com"
echo "  - Status    : https://status.apps.romain-ecarnot.com"
echo "  - Logs live : docker compose logs -f traefik"
```

- [ ] **Step 2 : Écrire `stop.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly INFRA_DIR="$(dirname "${SCRIPT_DIR}")"
cd "${INFRA_DIR}"
echo "[stop] Arret docker compose..."
docker compose down
echo "[stop] OK."
```

- [ ] **Step 3 : Écrire `backup-acme.sh`**

```bash
#!/usr/bin/env bash
# backup-acme.sh — Snapshot horodate de acme.json. A executer en cron daily.

set -euo pipefail

readonly INFRA_DIR="/opt/_infra"
readonly BACKUP_DIR="/opt/_backups/acme"
readonly RETENTION_DAYS=30

mkdir -p "${BACKUP_DIR}"

if [ ! -f "${INFRA_DIR}/data/acme.json" ]; then
  echo "[backup-acme] acme.json introuvable, abort." >&2
  exit 1
fi

ts="$(date -u +%Y%m%d-%H%M%S)"
dest="${BACKUP_DIR}/acme-${ts}.json"
cp "${INFRA_DIR}/data/acme.json" "${dest}"
chmod 600 "${dest}"
echo "[backup-acme] Backup : ${dest}"

# Retention : supprime les backups plus vieux que RETENTION_DAYS jours
find "${BACKUP_DIR}" -name 'acme-*.json' -mtime +${RETENTION_DAYS} -delete
echo "[backup-acme] Retention appliquee (>${RETENTION_DAYS}j supprimes)."
```

- [ ] **Step 4 : Rendre exécutables et valider syntaxe**

```bash
chmod +x templates/infra-bootstrap/scripts/{start,stop,backup-acme}.sh
for f in templates/infra-bootstrap/scripts/*.sh; do
  bash -n "$f" && echo "OK $f"
done
```

Expected : `OK` pour chaque script.

- [ ] **Step 5 : Lint shellcheck (optionnel)**

```bash
command -v shellcheck >/dev/null && \
  shellcheck templates/infra-bootstrap/scripts/*.sh || \
  echo "shellcheck non installe, skip"
```

Expected : aucune erreur, ou message "non installe".

- [ ] **Step 6 : Commit**

```bash
git add templates/infra-bootstrap/scripts/start.sh \
        templates/infra-bootstrap/scripts/stop.sh \
        templates/infra-bootstrap/scripts/backup-acme.sh
git commit -m "feat(infra-bootstrap): start/stop/backup-acme scripts"
```

---

### Task 8 : README.md complet du template

**Files:**
- Modify: `templates/infra-bootstrap/README.md`

- [ ] **Step 1 : Écrire le README complet**

```markdown
# Template `infra-bootstrap`

Squelette d'une stack d'infrastructure partagee Traefik + Uptime Kuma + sops/age + ACME Cloudflare DNS challenge.

## Quoi

- **Traefik v3** : reverse proxy unique, auto-discovery via labels Docker
- **ACME Cloudflare DNS-01** : certs Let's Encrypt wildcard `*.apps.romain-ecarnot.com`
- **sops + age** : secrets chiffres dans git
- **Uptime Kuma** : monitoring + alertes Telegram
- **Reseau partage** : `traefik-public` (external)

## Comment instancier

### 1. Cloner le template

```bash
cp -r vps-docker-manager/templates/infra-bootstrap/ vps-docker-manager-prod/
cd vps-docker-manager-prod/
git init && git add . && git commit -m "init from template"
```

### 2. Generer la cle age laptop (une fois)

```bash
brew install sops age
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
echo 'export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"' >> ~/.zshrc
source ~/.zshrc
grep '# public key' ~/.config/sops/age/keys.txt
```

Copier la cle publique `age1...` et remplacer `__AGE_PUBKEY_LAPTOP__` dans `.sops.yaml`.

### 3. Creer le token Cloudflare

Suivre le guide `docs/guide_cloudflare_sops_traefik.pdf` § 2.
Token scoped `Zone:DNS:Edit + Zone:Zone:Read` sur `romain-ecarnot.com`.

Recuperer le `CF_ZONE_ID` :

```bash
curl -s "https://api.cloudflare.com/client/v4/zones?name=romain-ecarnot.com" \
  -H "Authorization: Bearer ${CF_DNS_API_TOKEN}" | jq -r '.result[0].id'
```

### 4. Remplir les secrets

```bash
cp secrets.example.yaml secrets.yaml
# Editer secrets.yaml avec les vraies valeurs
sops --encrypt secrets.yaml > secrets.enc.yaml
rm secrets.yaml
```

### 5. Generer le hash bcrypt du dashboard

```bash
htpasswd -nBb admin "MonMotDePasseFort"
# Sortie type : admin:$2y$05$xxx...
# A coller dans secrets.yaml > traefik > DASHBOARD_BASIC_AUTH
# (ne PAS doubler les $ ici, c'est sops qui les manipule)
```

### 6. Bootstrap VPS (premier run)

```bash
# Pousser le repo prod sur GitHub prive, puis sur le VPS :
ssh root@VPS "git clone <url-prive> /opt/_infra"
ssh root@VPS "cd /opt/_infra && ./scripts/bootstrap-vps.sh"
```

Le script s'arrete apres avoir genere la cle age VPS. Recuperer la cle publique affichee, l'ajouter dans `.sops.yaml` (`__AGE_PUBKEY_VPS__`), puis :

```bash
sops updatekeys secrets.enc.yaml
git commit -am "feat: add VPS age key"
git push
ssh root@VPS "cd /opt/_infra && git pull && ./scripts/bootstrap-vps.sh"
```

### 7. Demarrer

```bash
ssh root@VPS "cd /opt/_infra && ./scripts/start.sh"
```

### 8. Switch staging -> prod LE

Apres validation que les certs staging sont bien generes :

```bash
ssh root@VPS
cd /opt/_infra
# Editer traefik/traefik.yml : commenter caServer staging, decommenter prod
nano traefik/traefik.yml
rm data/acme.json && touch data/acme.json && chmod 600 data/acme.json
docker compose restart traefik
```

Verifier le cert :

```bash
curl -vI https://traefik.apps.romain-ecarnot.com 2>&1 | grep -E "issuer|subject"
```

## Layout sur le VPS

```
/opt/_infra/                        ← ce repo
/opt/_data/                         ← volumes apps (vide initialement)
/opt/_backups/                      ← snapshots data + acme.json
/root/.config/sops/age/keys.txt     ← cle age privee VPS
```

## Cron backup acme

```bash
echo '0 3 * * * /opt/_infra/scripts/backup-acme.sh >> /var/log/backup-acme.log 2>&1' | crontab -
```

## Modele de labels pour les projets applicatifs

```yaml
mon-app:
  labels:
    - "traefik.enable=true"
    - "traefik.http.routers.monapp.rule=Host(`monapp.apps.romain-ecarnot.com`)"
    - "traefik.http.routers.monapp.entrypoints=websecure"
    - "traefik.http.routers.monapp.tls.certresolver=acme-cloudflare"
    - "traefik.http.routers.monapp.middlewares=security-headers@file"
    - "traefik.http.services.monapp.loadbalancer.server.port=3000"
  networks:
    - traefik-public
    - monapp-internal
```

## References

- Spec design : `docs/superpowers/specs/2026-04-25-infra-bootstrap-design.md`
- Guide Cloudflare/sops/Traefik : `docs/guide_cloudflare_sops_traefik.pdf`
- Inventaire pre-migration : `docs/inventory.md`
```

- [ ] **Step 2 : Commit**

```bash
git add templates/infra-bootstrap/README.md
git commit -m "docs(infra-bootstrap): full README with instantiation procedure"
```

---

### Task 9 : Validation globale du template

- [ ] **Step 1 : Validation syntaxe complète**

```bash
echo "=== YAML ===" && \
for f in $(find templates/infra-bootstrap -name "*.yml" -o -name "*.yaml"); do
  python3 -c "import yaml; yaml.safe_load(open('$f'))" && echo "OK $f"
done

echo "=== Bash ===" && \
for f in templates/infra-bootstrap/scripts/*.sh; do
  bash -n "$f" && echo "OK $f"
done

echo "=== Compose config ===" && \
docker compose -f templates/infra-bootstrap/docker-compose.yml config --quiet 2>&1 | head -5
```

Expected : tous `OK`. L'erreur "external network not found" sur compose config est attendue en local.

- [ ] **Step 2 : Listing final**

```bash
tree templates/infra-bootstrap/ -a -I '.git'
```

Expected : structure conforme à la section "File structure" de ce plan.

- [ ] **Step 3 : Push origin (si remote configuré)**

```bash
git remote -v
# Si origin existe :
# git push -u origin main
```

Expected : push OK ou message "no upstream configured" (à régler par Romain).

---

## Phase 2 — Setup local laptop (manuel, assisté)

### Task 10 : Pré-requis sops/age sur le laptop

- [ ] **Step 1 : Installer sops et age**

```bash
brew install sops age
sops --version  # >= 3.9
age --version   # >= 1.1
```

Expected : versions affichées.

- [ ] **Step 2 : Générer la clé age laptop**

```bash
mkdir -p ~/.config/sops/age
if [ -f ~/.config/sops/age/keys.txt ]; then
  echo "Cle deja existante, conservee."
else
  age-keygen -o ~/.config/sops/age/keys.txt
fi
chmod 600 ~/.config/sops/age/keys.txt
```

- [ ] **Step 3 : Configurer la variable d'env**

```bash
grep -q SOPS_AGE_KEY_FILE ~/.zshrc || \
  echo 'export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"' >> ~/.zshrc
source ~/.zshrc
echo $SOPS_AGE_KEY_FILE
```

Expected : `/Users/recarnot/.config/sops/age/keys.txt`.

- [ ] **Step 4 : Récupérer la clé publique laptop**

```bash
grep '# public key' ~/.config/sops/age/keys.txt
```

Expected : ligne `# public key: age1...`. **Noter cette valeur pour la Task 14.**

---

### Task 11 : Création du token Cloudflare

- [ ] **Step 1 : Créer le token (UI manuelle)**

Suivre le guide `docs/guide_cloudflare_sops_traefik.pdf` § 2 :

1. Aller sur https://dash.cloudflare.com/profile/api-tokens
2. Create Token → "Edit zone DNS" template
3. Permissions : `Zone:DNS:Edit` + `Zone:Zone:Read`
4. Zone Resources : `Specific zone` → `romain-ecarnot.com`
5. Continue → Create Token → **copier le token immédiatement**

- [ ] **Step 2 : Tester le token**

```bash
export CF_DNS_API_TOKEN="<coller-le-token-ici>"
curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
  -H "Authorization: Bearer ${CF_DNS_API_TOKEN}" \
  -H "Content-Type: application/json" | jq .
```

Expected : `"status": "active"` et `"success": true`.

- [ ] **Step 3 : Récupérer le CF_ZONE_ID**

```bash
curl -s "https://api.cloudflare.com/client/v4/zones?name=romain-ecarnot.com" \
  -H "Authorization: Bearer ${CF_DNS_API_TOKEN}" | jq -r '.result[0].id'
```

Expected : un ID hexadécimal de 32 caractères. **Noter pour la Task 15.**

---

### Task 12 : Bot Telegram pour Uptime Kuma

- [ ] **Step 1 : Créer le bot Telegram**

1. Ouvrir Telegram, chercher `@BotFather`
2. `/newbot`, suivre les instructions, choisir un nom (ex: `vps-uptime-bot`)
3. Récupérer le **token** affiché.

- [ ] **Step 2 : Récupérer le chat ID destination**

1. Démarrer une conversation avec le bot (`/start`)
2. Récupérer l'ID :

```bash
TG_TOKEN="<bot-token>"
curl -s "https://api.telegram.org/bot${TG_TOKEN}/getUpdates" | jq -r '.result[0].message.chat.id'
```

Expected : un nombre (entier signé). **Noter pour la Task 15.**

---

## Phase 3 — Création du repo `vps-docker-manager-prod`

### Task 13 : Créer le repo privé GitHub

- [ ] **Step 1 : Créer le repo via gh CLI**

```bash
cd ~/dev
gh repo create vps-docker-manager-prod --private --description "Etat instancie de l'infra VPS (sops chiffre)"
```

Expected : `https://github.com/<user>/vps-docker-manager-prod` créé.

- [ ] **Step 2 : Cloner le template dans un nouveau dossier**

```bash
cd ~/dev
cp -r vps-docker-manager/templates/infra-bootstrap vps-docker-manager-prod-tmp
mv vps-docker-manager-prod-tmp/* vps-docker-manager-prod-tmp/.[!.]* /tmp/staging-infra/ 2>/dev/null || true
mkdir -p vps-docker-manager-prod
cp -r vps-docker-manager/templates/infra-bootstrap/. vps-docker-manager-prod/
cd vps-docker-manager-prod
git init -b main
git remote add origin "$(gh repo view vps-docker-manager-prod --json sshUrl -q .sshUrl)"
```

Expected : `git status` montre tous les fichiers du template prêts à commiter.

---

### Task 14 : Instancier `.sops.yaml` avec la clé age laptop

**Files:**
- Modify: `~/dev/vps-docker-manager-prod/.sops.yaml`

- [ ] **Step 1 : Substituer la clé laptop**

Récupérer la clé :

```bash
LAPTOP_KEY=$(grep '# public key' ~/.config/sops/age/keys.txt | sed 's/# public key: //')
echo "${LAPTOP_KEY}"
```

- [ ] **Step 2 : Remplacer `__AGE_PUBKEY_LAPTOP__` dans `.sops.yaml`**

```bash
cd ~/dev/vps-docker-manager-prod
sed -i '' "s|__AGE_PUBKEY_LAPTOP__|${LAPTOP_KEY}|g" .sops.yaml
cat .sops.yaml
```

Expected : la clé laptop est insérée. `__AGE_PUBKEY_VPS__` reste pour le moment.

- [ ] **Step 3 : Commit (sans secrets encore)**

```bash
git add .sops.yaml
git commit -m "chore: inject laptop age key in .sops.yaml"
```

---

### Task 15 : Créer et chiffrer `secrets.yaml`

**Files:**
- Create: `~/dev/vps-docker-manager-prod/secrets.yaml` (temporaire, supprimé en step 5)
- Create: `~/dev/vps-docker-manager-prod/secrets.enc.yaml`

- [ ] **Step 1 : Générer le hash bcrypt du dashboard**

```bash
brew install httpd 2>/dev/null || true   # fournit htpasswd
htpasswd -nBb admin "RemplaceParUnMotDePasseFort"
# Sortie : admin:$2y$05$xxx...
```

**Noter la sortie complète, c'est la valeur à mettre dans `DASHBOARD_BASIC_AUTH`.**

- [ ] **Step 2 : Créer `secrets.yaml` (temporaire)**

```bash
cd ~/dev/vps-docker-manager-prod
cat > secrets.yaml <<'EOF'
cloudflare:
  CF_DNS_API_TOKEN: "REMPLACER_PAR_TOKEN_TASK11"
  CF_ZONE_ID: "REMPLACER_PAR_ZONE_ID_TASK11"

traefik:
  DASHBOARD_BASIC_AUTH: "REMPLACER_PAR_HTPASSWD_STEP1"

uptime_kuma:
  TELEGRAM_BOT_TOKEN: "REMPLACER_PAR_TOKEN_TASK12"
  TELEGRAM_CHAT_ID: "REMPLACER_PAR_CHAT_ID_TASK12"
EOF
nano secrets.yaml   # remplacer toutes les valeurs
```

- [ ] **Step 3 : Chiffrer**

Important : sops ne peut pas encore chiffrer pour le VPS (clé pas encore générée). On chiffre uniquement avec la clé laptop pour l'instant. Pour cela, retirer temporairement `__AGE_PUBKEY_VPS__` de `.sops.yaml` :

```bash
cd ~/dev/vps-docker-manager-prod
# Sauvegarder la version "complete" pour Task 19
cp .sops.yaml .sops.yaml.full
# Retirer la ligne VPS pour le chiffrement initial
sed -i '' '/__AGE_PUBKEY_VPS__/d' .sops.yaml
sops --encrypt secrets.yaml > secrets.enc.yaml
# Restaurer la version complete (sera vraiment utilisable apres Task 19)
mv .sops.yaml.full .sops.yaml
```

- [ ] **Step 4 : Vérifier le déchiffrement**

```bash
sops --decrypt secrets.enc.yaml | head -5
```

Expected : YAML déchiffré visible (valeurs réelles).

- [ ] **Step 5 : Supprimer le fichier en clair**

```bash
rm secrets.yaml
ls -la secrets*
```

Expected : seul `secrets.enc.yaml` présent. `.gitignore` (hérité du template) protège déjà `secrets.yaml`.

- [ ] **Step 6 : Commit**

```bash
git add secrets.enc.yaml
git commit -m "feat: add encrypted secrets (laptop key only, VPS key pending)"
git push -u origin main
```

---

## Phase 4 — Pré-bootstrap VPS (backup + wipe préparation)

### Task 16 : Snapshot pré-wipe du VPS

- [ ] **Step 1 : Créer le tarball côté VPS**

```bash
TS=$(date +%Y%m%d-%H%M%S)
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 \
  "tar czf /tmp/snapshot-${TS}.tgz \
     /opt/trinity-lifeos/data \
     /opt/trinity-lifeos/vps/docker/.env \
     /opt/trinity-lifeos/vps/docker/caddy/Caddyfile \
     /opt/buck-writer-app/data \
     /opt/buck-writer-app/vps/.env.production \
     /opt/buck-writer-app/vps/.env.trinity \
     /opt/buck-writer-app/vps/Caddyfile 2>/dev/null || true"
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 "ls -lh /tmp/snapshot-*.tgz"
```

Expected : tarball présent, taille >0.

- [ ] **Step 2 : Récupérer le tarball en local**

```bash
mkdir -p ~/Backups/vps-pre-migration
scp -i ~/.ssh/id_vps20260131 \
    root@72.62.239.98:/tmp/snapshot-${TS}.tgz \
    ~/Backups/vps-pre-migration/
ls -lh ~/Backups/vps-pre-migration/
```

Expected : fichier copié, taille identique au step 1.

- [ ] **Step 3 : Vérifier l'intégrité du tarball**

```bash
tar tzf ~/Backups/vps-pre-migration/snapshot-${TS}.tgz | head -20
```

Expected : listing des fichiers data Trinity + Buck.

- [ ] **Step 4 : Sauvegarde clé age laptop (sécurité)**

```bash
cp ~/.config/sops/age/keys.txt ~/Backups/vps-pre-migration/age-laptop-${TS}.txt
echo "Clé age laptop sauvegardée. Pense à la copier dans 1Password aussi."
```

---

## Phase 5 — Bootstrap VPS

### Task 17 : DNS Cloudflare

- [ ] **Step 1 : Créer les A records dans Cloudflare**

Manuel via UI dash.cloudflare.com → romain-ecarnot.com → DNS → Records :

| Type | Name | Content | Proxy | TTL |
|---|---|---|---|---|
| A | `apps` | `72.62.239.98` | DNS only (gris) | 60 |
| A | `*.apps` | `72.62.239.98` | DNS only (gris) | 60 |
| A | `*.buck.apps` | `72.62.239.98` | DNS only (gris) | 60 |

**Important** : proxy Cloudflare DOIT être désactivé (gris, pas orange) pour que Traefik gère les certs.

- [ ] **Step 2 : Vérifier la propagation**

```bash
dig +short traefik.apps.romain-ecarnot.com @1.1.1.1
dig +short n8n.apps.romain-ecarnot.com @1.1.1.1
dig +short bible.buck.apps.romain-ecarnot.com @1.1.1.1
```

Expected : `72.62.239.98` pour les 3.

---

### Task 18 : Wipe Docker sur le VPS

- [ ] **Step 1 : Stopper toutes les stacks existantes**

```bash
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 << 'EOF'
set -x
cd /opt/trinity-lifeos/vps/docker && docker compose down -v 2>/dev/null || true
cd /opt/buck-writer-app/vps && docker compose down -v 2>/dev/null || true
EOF
```

- [ ] **Step 2 : Prune complet**

```bash
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 << 'EOF'
docker system prune -af --volumes
docker network prune -f
docker ps -a
docker volume ls
docker network ls
EOF
```

Expected : `docker ps -a` vide. `docker volume ls` vide. `docker network ls` ne contient plus que `bridge`, `host`, `none`.

---

### Task 19 : Cloner le repo prod sur le VPS + premier run bootstrap

- [ ] **Step 1 : Préparer la clé deploy SSH GitHub (lecture seule)**

```bash
# Sur le VPS, generer une cle SSH dediee :
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 \
  "test -f /root/.ssh/id_github_deploy || ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_github_deploy"
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 "cat /root/.ssh/id_github_deploy.pub"
```

Copier la clé publique. L'ajouter comme **Deploy Key (read-only)** dans le repo `vps-docker-manager-prod` sur GitHub :

- Settings → Deploy keys → Add deploy key → coller la clé → ne PAS cocher write access.

- [ ] **Step 2 : Configurer SSH pour utiliser cette clé pour github.com**

```bash
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 << 'EOF'
cat >> /root/.ssh/config <<CONFIG
Host github.com
  HostName github.com
  User git
  IdentityFile /root/.ssh/id_github_deploy
  IdentitiesOnly yes
CONFIG
chmod 600 /root/.ssh/config
ssh -T git@github.com 2>&1 | head -3
EOF
```

Expected : `Hi <user>/vps-docker-manager-prod! You've successfully authenticated...`.

- [ ] **Step 3 : Cloner le repo dans /opt/_infra**

```bash
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 \
  "git clone git@github.com:$(gh api user --jq .login)/vps-docker-manager-prod.git /opt/_infra"
```

Expected : repo cloné dans `/opt/_infra/`.

- [ ] **Step 4 : Premier run de bootstrap-vps.sh (génération clé age VPS)**

```bash
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 \
  "cd /opt/_infra && ./scripts/bootstrap-vps.sh"
```

Expected : installation des prereqs (docker, age, sops), création des dossiers, **génération de la clé age VPS**, affichage de la clé publique, **arrêt avec instructions**.

- [ ] **Step 5 : Récupérer la clé publique VPS**

```bash
VPS_KEY=$(ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 \
  "grep '# public key' /root/.config/sops/age/keys.txt | sed 's/# public key: //'")
echo "Cle publique VPS : ${VPS_KEY}"
```

**Noter cette valeur pour la Task 20.**

---

### Task 20 : Re-chiffrer les secrets pour la clé VPS + 2nd run

**Files:**
- Modify: `~/dev/vps-docker-manager-prod/.sops.yaml`
- Modify: `~/dev/vps-docker-manager-prod/secrets.enc.yaml`

- [ ] **Step 1 : Substituer la clé VPS dans `.sops.yaml`**

```bash
cd ~/dev/vps-docker-manager-prod
sed -i '' "s|__AGE_PUBKEY_VPS__|${VPS_KEY}|g" .sops.yaml
cat .sops.yaml
```

Expected : `.sops.yaml` contient les deux clés (laptop + VPS).

- [ ] **Step 2 : Re-chiffrer `secrets.enc.yaml` pour ajouter la clé VPS**

```bash
sops updatekeys secrets.enc.yaml
```

Si une question interactive apparaît, répondre `y`.

- [ ] **Step 3 : Vérifier que les deux clés sont reconnues**

```bash
grep -c "age:" secrets.enc.yaml
sops --decrypt secrets.enc.yaml | head -3
```

Expected : déchiffrement OK localement (avec clé laptop).

- [ ] **Step 4 : Commit + push**

```bash
git add .sops.yaml secrets.enc.yaml
git commit -m "feat: add VPS age key + rekey secrets"
git push
```

- [ ] **Step 5 : Pull sur le VPS + 2nd run bootstrap**

```bash
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 << 'EOF'
cd /opt/_infra
git pull
./scripts/bootstrap-vps.sh
EOF
```

Expected : pas de re-génération de clé. Création du réseau `traefik-public`, prepare `acme.json`. Message final "Lancer ./scripts/start.sh".

- [ ] **Step 6 : Vérifier que le VPS peut déchiffrer**

```bash
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 \
  "cd /opt/_infra && SOPS_AGE_KEY_FILE=/root/.config/sops/age/keys.txt sops --decrypt secrets.enc.yaml | head -3"
```

Expected : YAML déchiffré visible côté VPS.

---

## Phase 6 — Premier démarrage Traefik (staging LE)

### Task 21 : Lancer la stack en mode staging

- [ ] **Step 1 : Premier démarrage**

```bash
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 \
  "cd /opt/_infra && SOPS_AGE_KEY_FILE=/root/.config/sops/age/keys.txt ./scripts/start.sh"
```

Expected : déchiffrement OK, htpasswd écrit, `docker compose up -d` lance traefik et uptime-kuma. Logs Traefik affichés.

- [ ] **Step 2 : Vérifier les conteneurs**

```bash
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 \
  "cd /opt/_infra && docker compose ps"
```

Expected : `traefik` et `uptime-kuma` en `Up`.

- [ ] **Step 3 : Vérifier la génération du cert staging**

```bash
sleep 60   # le DNS challenge prend ~30-60s
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 \
  "cd /opt/_infra && docker compose logs traefik --tail=100 | grep -E 'acme|certificate|error'"
```

Expected : pas d'erreur 401/403 Cloudflare. Lignes "Obtained certificate" ou "Certificate from Letsencrypt staging".

- [ ] **Step 4 : Test HTTPS depuis l'extérieur (cert auto-signé attendu)**

```bash
curl -vIk https://traefik.apps.romain-ecarnot.com 2>&1 | grep -E "issuer|subject|HTTP/"
```

Expected : HTTP/2 401 (basicauth) ou 200. **Issuer doit contenir "STAGING"** (Let's Encrypt staging CA).

- [ ] **Step 5 : Vérifier basicauth**

```bash
curl -uk admin:RemplaceParUnMotDePasseFort -k https://traefik.apps.romain-ecarnot.com/dashboard/ -I
```

Expected : `HTTP/2 200`.

- [ ] **Step 6 : Vérifier Uptime Kuma accessible**

```bash
curl -Ik https://status.apps.romain-ecarnot.com 2>&1 | grep -E "HTTP/|issuer"
```

Expected : `HTTP/2 200` (Uptime Kuma a son propre login interne, pas de basicauth).

---

## Phase 7 — Switch en prod LE

### Task 22 : Bascule staging → prod

**Files:**
- Modify: `/opt/_infra/traefik/traefik.yml` (sur le VPS)

- [ ] **Step 1 : Éditer `traefik.yml` sur le VPS**

```bash
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98
cd /opt/_infra
sed -i 's|^      caServer: https://acme-staging|      # caServer: https://acme-staging|' traefik/traefik.yml
sed -i 's|^      # caServer: https://acme-v02|      caServer: https://acme-v02|' traefik/traefik.yml
grep caServer traefik/traefik.yml
```

Expected : seul `caServer: https://acme-v02...` non commenté.

- [ ] **Step 2 : Vider acme.json + restart Traefik**

```bash
rm data/acme.json
touch data/acme.json
chmod 600 data/acme.json
docker compose restart traefik
sleep 60
docker compose logs traefik --tail=50 | grep -E "acme|certificate"
```

Expected : nouvelles lignes "Obtained certificate" pour `*.apps.romain-ecarnot.com` (sans "staging" dans le nom).

- [ ] **Step 3 : Vérifier le cert prod depuis l'extérieur**

```bash
exit   # back to laptop
curl -vI https://traefik.apps.romain-ecarnot.com 2>&1 | grep -E "issuer|subject"
```

Expected : `issuer` contient `Let's Encrypt`, **PAS `STAGING`**. Le navigateur ne devrait plus alerter.

- [ ] **Step 4 : Commit la modif sur le repo prod**

```bash
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 << 'EOF'
cd /opt/_infra
git add traefik/traefik.yml
git commit -m "chore: switch ACME to prod LE"
git push
EOF
```

Note : le push depuis le VPS échouera si la deploy key est read-only. Dans ce cas, faire le commit en local et pull sur le VPS :

```bash
cd ~/dev/vps-docker-manager-prod
git pull   # synchronise si ok
# OU re-appliquer le sed en local :
sed -i '' 's|^      caServer: https://acme-staging|      # caServer: https://acme-staging|' traefik/traefik.yml
sed -i '' 's|^      # caServer: https://acme-v02|      caServer: https://acme-v02|' traefik/traefik.yml
git commit -am "chore: switch ACME to prod LE"
git push
ssh root@VPS "cd /opt/_infra && git pull"
```

---

### Task 23 : Configurer Uptime Kuma + Telegram

- [ ] **Step 1 : Setup admin Uptime Kuma**

Ouvrir https://status.apps.romain-ecarnot.com dans le navigateur.

Page d'init : créer le compte admin (username + password fort, à stocker dans 1Password).

- [ ] **Step 2 : Configurer le bot Telegram comme notification**

Dans Uptime Kuma : Settings → Notifications → Setup Notification :
- Type : Telegram
- Bot Token : valeur de `secrets.enc.yaml > uptime_kuma > TELEGRAM_BOT_TOKEN`
- Chat ID : valeur de `secrets.enc.yaml > uptime_kuma > TELEGRAM_CHAT_ID`
- Test → vérifier que Telegram reçoit "Test message"

- [ ] **Step 3 : Ajouter les premiers monitors (smoke test)**

Add New Monitor :
- Monitor Type : HTTPS
- Friendly Name : "Traefik Dashboard"
- URL : `https://traefik.apps.romain-ecarnot.com`
- Heartbeat Interval : 60s
- Notifications : cocher Telegram
- Save

Idem pour `https://status.apps.romain-ecarnot.com`.

- [ ] **Step 4 : Tester l'alerte (down forcé)**

```bash
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 \
  "cd /opt/_infra && docker compose stop traefik"
sleep 90
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 \
  "cd /opt/_infra && docker compose start traefik"
```

Expected : message Telegram "DOWN" reçu sur le chat configuré, puis "UP" après restart.

---

## Phase 8 — Backup automation + critères d'acceptation

### Task 24 : Cron daily backup-acme

- [ ] **Step 1 : Installer le cron**

```bash
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 << 'EOF'
( crontab -l 2>/dev/null | grep -v 'backup-acme.sh' ; \
  echo '0 3 * * * /opt/_infra/scripts/backup-acme.sh >> /var/log/backup-acme.log 2>&1' ) \
  | crontab -
crontab -l
EOF
```

Expected : ligne de cron visible dans la liste.

- [ ] **Step 2 : Test manuel du script**

```bash
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 \
  "/opt/_infra/scripts/backup-acme.sh && ls -lh /opt/_backups/acme/"
```

Expected : un fichier `acme-YYYYMMDD-HHMMSS.json` créé, chmod 600.

---

### Task 25 : Validation des critères d'acceptation de la spec

- [ ] **Step 1 : Cocher chaque critère de la section 10 de la spec**

Critères (depuis `docs/superpowers/specs/2026-04-25-infra-bootstrap-design.md` § 10) :

```bash
echo "=== Critère 1 : bootstrap-vps.sh idempotent ==="
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 \
  "cd /opt/_infra && ./scripts/bootstrap-vps.sh && ./scripts/bootstrap-vps.sh"
# Attendu : 2 runs successifs sans erreur

echo "=== Critère 2 : reseau traefik-public ==="
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 "docker network ls | grep traefik-public"
# Attendu : ligne visible

echo "=== Critère 3 : conteneurs healthy ==="
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 "cd /opt/_infra && docker compose ps"
# Attendu : traefik et uptime-kuma "Up"

echo "=== Critère 4 : dashboard 401/200 + LE prod ==="
curl -I https://traefik.apps.romain-ecarnot.com 2>&1 | grep "401"
curl -uk admin:<password> -I https://traefik.apps.romain-ecarnot.com 2>&1 | grep "200"
echo | openssl s_client -connect traefik.apps.romain-ecarnot.com:443 2>/dev/null | grep -E "issuer|CN"
# Attendu : 401 sans auth, 200 avec, issuer = Let's Encrypt (pas STAGING)

echo "=== Critère 5 : Uptime Kuma accessible + LE prod ==="
curl -I https://status.apps.romain-ecarnot.com 2>&1 | grep "200"

echo "=== Critère 6 : alerte Telegram (test deja fait Task 23) ==="

echo "=== Critère 7 : backup-acme cron (test deja fait Task 24) ==="

echo "=== Critère 8 : Trinity et Buck encore fonctionnels ==="
# WARNING : ils sont DOWN suite au wipe Task 18.
# Ce critère sera re-validé au sous-projet migration-trinity-buck.
# Pour l'instant on confirme juste que l'infra _infra ne prend pas leur place.

echo "=== Critère 9 : commits dans vps-docker-manager ==="
cd ~/dev/vps-docker-manager && git log --oneline -10

echo "=== Critère 10 : repo prive vps-docker-manager-prod ==="
gh repo view vps-docker-manager-prod
```

Expected : tous les critères répondent comme attendu, sauf le critère 8 qui est déplacé au sous-projet de migration.

- [ ] **Step 2 : Mettre à jour la spec si un critère doit être déplacé**

Le critère 8 ("Trinity et Buck toujours fonctionnels en parallèle") nécessite que le **wipe** soit déplacé du Task 18 actuel vers le sous-projet `migration-trinity-buck`. **Décision** : Romain a explicitement validé "VPS actuel + full clear Docker", donc le critère 8 est déplacé/supprimé. À documenter :

```bash
cd ~/dev/vps-docker-manager
# Editer la spec : retirer le critère 8 ou le reformuler.
nano docs/superpowers/specs/2026-04-25-infra-bootstrap-design.md
git commit -am "docs(spec): align critère 8 with full-wipe decision"
git push
```

- [ ] **Step 3 : Tag de la version infra-bootstrap v0.1.0**

```bash
cd ~/dev/vps-docker-manager
git tag -a infra-bootstrap-v0.1.0 -m "infra-bootstrap initial release"
git push origin infra-bootstrap-v0.1.0

cd ~/dev/vps-docker-manager-prod
git tag -a v0.1.0 -m "First prod deployment of _infra stack"
git push origin v0.1.0
```

---

## Récapitulatif des phases

| Phase | Tasks | Durée estimée |
|---|---|---|
| 1. Templates `vps-docker-manager` | 1-9 | ~2h (écriture + validation) |
| 2. Setup local laptop | 10-12 | ~30min (manuel guidé) |
| 3. Repo `vps-docker-manager-prod` | 13-15 | ~30min |
| 4. Pré-bootstrap (backup) | 16 | ~10min |
| 5. Bootstrap VPS | 17-20 | ~30min |
| 6. Premier démarrage staging | 21 | ~15min |
| 7. Switch prod LE | 22-23 | ~30min |
| 8. Backup + acceptation | 24-25 | ~30min |

**Total estimé** : 4h30, à étaler sur 1-2 sessions.

---

## Post-implémentation

Une fois `infra-bootstrap` opérationnel et tagué v0.1.0, ouvrir le sous-projet suivant : **`migration-trinity-buck`** (brainstorming + spec dédiée), qui consommera l'infra posée ici pour rebrancher progressivement Trinity (n8n) puis Buck.
