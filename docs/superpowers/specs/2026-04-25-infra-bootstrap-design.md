# Spec — `infra-bootstrap`

**Date** : 2026-04-25
**Auteur** : Romain Ecarnot
**Sous-projet** : `infra-bootstrap` (1/6 du programme `vps-docker-manager`)
**Statut** : design validé

---

## 1. Contexte

Le VPS Hostinger `72.62.239.98` héberge actuellement deux projets (Trinity LifeOS, Buck Writer App) avec deux stratégies de déploiement divergentes, un Caddy partagé hébergé par Trinity, des secrets `.env` plaintext qui voyagent en `scp`, et un couplage fort où le `deploy.sh` de Buck modifie l'infra de Trinity.

À court terme, Romain prévoit d'ajouter au moins 3 projets supplémentaires (`agent-brain`, `agent-cross-memory`, +1 nouveau). L'organisation actuelle ne tient pas la charge. Voir `docs/inventory.md` pour l'état des lieux complet.

`infra-bootstrap` est le premier maillon d'un programme plus large (`vps-docker-manager`) qui posera les fondations sur lesquelles tous les projets se brancheront.

## 2. Objectif

Poser sur le VPS une stack d'infrastructure partagée (Traefik + ACME Cloudflare + secrets sops + monitoring Uptime Kuma) qui :

- Sert de point d'entrée HTTPS unique pour tous les projets applicatifs.
- Permet à un nouveau projet d'être exposé en ajoutant uniquement des labels Docker (zéro modif de l'infra partagée).
- Stocke ses secrets chiffrés dans git (sops/age), avec déchiffrement transparent au boot.
- Fournit un monitoring out-of-the-box avec alertes Telegram.
- Est rejouable et reproductible via un script `bootstrap-vps.sh` idempotent.

**Critère de "done"** : `https://traefik.apps.romain-ecarnot.com` et `https://status.apps.romain-ecarnot.com` répondent avec des certs Let's Encrypt valides, **pendant que Trinity et Buck continuent de tourner sur l'ancienne config en parallèle**. Le cutover applicatif fait l'objet d'un sous-projet séparé (`migration-trinity-buck`).

## 3. Décisions structurelles validées

| # | Décision | Rationale |
|---|---|---|
| D1 | Reverse proxy : **Traefik v3** (remplace Caddy) | Auto-discovery via labels Docker, plus naturel pour multi-projets |
| D2 | Challenge ACME : **DNS-01 via API Cloudflare** | Permet wildcards `*.apps.romain-ecarnot.com`, fonctionne sans port 80 ouvert |
| D3 | Secrets : **sops + age** | Chiffrement git-friendly, multi-clés, simple, pas de SaaS |
| D4 | Layout domaines : **`<service>.apps.romain-ecarnot.com`** | Sépare apps du site perso, scalable |
| D5 | VPS : **réutiliser le VPS Hostinger actuel** + full clear Docker | Pas de coût supplémentaire, snapshot pré-wipe pour rollback |
| D6 | Repos : **public `vps-docker-manager`** (templates) + **privé `vps-docker-manager-prod`** (état VPS instancié) | Tooling open-source-friendly, état prod isolé |
| D7 | Layout VPS : `/opt/_infra/`, `/opt/_data/`, `/opt/_backups/`, `/opt/<projet>/` | Convention claire, séparation infra/data/projets |
| D8 | Réseau partagé : **`traefik-public`** | Aligné sur la convention du guide PDF de Romain |
| D9 | Dashboard Traefik : **exposé sur `traefik.apps.*` + basicauth** | Debug visuel facile |
| D10 | Premier boot ACME : **staging Let's Encrypt** puis switch prod | Évite de brûler le rate limit (5 certs/semaine/domaine) en cas d'erreur de config |
| D11 | Monitoring : **Uptime Kuma** sidecar dans `_infra` + alertes Telegram | UI prête, RAM faible, intégrable au bot Telegram existant |

## 4. Architecture

```
                                    Internet
                                       │
                              [80/443] ▼
                          ┌─────────────────┐
                          │     Traefik     │  ← unique entrée publique
                          │   (v3, ACME)    │
                          └────────┬────────┘
                                   │ traefik-public (network)
              ┌────────────────────┼────────────────────┬─────────────┐
              ▼                    ▼                    ▼             ▼
        ┌─────────┐          ┌─────────┐          ┌─────────┐   ┌──────────┐
        │  Buck   │          │   n8n   │          │  Bible  │   │  Uptime  │
        │  app    │          │ Trinity │          │   MCP   │   │   Kuma   │
        └────┬────┘          └────┬────┘          └────┬────┘   └──────────┘
             │ buck-internal      │ trinity-internal  │ buck-internal
        ┌────▼─────┐         ┌────▼────┐        ┌────▼─────┐
        │ buck-db  │         │ n8n-db  │        │ bible-db │
        └──────────┘         └─────────┘        └──────────┘
```

- **`traefik-public`** : seul réseau partagé, créé par `bootstrap-vps.sh`. Les services applicatifs s'y connectent pour être routés.
- **`<projet>-internal`** : réseaux privés par projet pour leur stack interne (db, sidecars).
- **ACME** : un seul résolveur, certs wildcards `*.apps.romain-ecarnot.com` mutualisés, stockés dans `/opt/_infra/data/acme.json` (chmod 600).

## 5. Arborescence

### 5.1 Repo public `vps-docker-manager`

```
vps-docker-manager/
├── README.md
├── CLAUDE.md
├── .cave/
├── docs/
│   ├── inventory.md
│   ├── guide_cloudflare_sops_traefik.pdf
│   └── superpowers/specs/2026-04-25-infra-bootstrap-design.md
└── templates/
    └── infra-bootstrap/
        ├── docker-compose.yml
        ├── traefik/
        │   ├── traefik.yml
        │   └── dynamic/
        │       ├── middlewares.yml
        │       └── tls.yml
        ├── .sops.yaml
        ├── secrets.example.yaml
        ├── scripts/
        │   ├── bootstrap-vps.sh
        │   ├── start.sh
        │   ├── stop.sh
        │   └── backup-acme.sh
        └── README.md
```

### 5.2 Repo privé `vps-docker-manager-prod`

Clone du template ci-dessus, instancié avec les vraies valeurs. Vit en local sur le laptop, push sur GitHub privé, pull sur le VPS dans `/opt/_infra/`.

```
vps-docker-manager-prod/
├── README.md
├── docker-compose.yml
├── traefik/
│   ├── traefik.yml
│   └── dynamic/
│       ├── middlewares.yml
│       └── tls.yml
├── .sops.yaml                  ← liste des clés age autorisées (laptop + VPS)
├── secrets.enc.yaml            ← chiffré sops
├── data/                       ← gitignored (volumes runtime)
│   ├── acme.json
│   └── uptime-kuma/
├── scripts/
│   ├── bootstrap-vps.sh
│   ├── start.sh
│   ├── stop.sh
│   └── backup-acme.sh
└── .gitignore
```

`secrets.enc.yaml` contient (structure en clair, valeurs chiffrées) :

```yaml
cloudflare:
  CF_DNS_API_TOKEN: <token Zone:DNS:Edit + Zone:Zone:Read>
  CF_ZONE_ID: <id zone romain-ecarnot.com>
traefik:
  DASHBOARD_BASIC_AUTH: <user:bcrypt-hash>
uptime_kuma:
  TELEGRAM_BOT_TOKEN: <bot token>
  TELEGRAM_CHAT_ID: <chat id>
```

### 5.3 Layout sur le VPS

```
/opt/_infra/                        ← git clone de vps-docker-manager-prod
/opt/_data/                         ← volumes apps (vide initialement)
/opt/_backups/                      ← snapshots data + acme.json
/root/.config/sops/age/keys.txt     ← clé age privée du VPS (déposée à la main)
```

## 6. Procédure de bootstrap

### 6.1 Pré-requis local (laptop, une fois)

```bash
brew install sops age
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
echo 'export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"' >> ~/.zshrc
```

→ Récupérer la clé publique laptop (`age1...`) pour `.sops.yaml`.

### 6.2 Token Cloudflare

Suivre le guide PDF (§ 2). Token scoped `Zone:DNS:Edit + Zone:Zone:Read` sur `romain-ecarnot.com`. À copier dans `secrets.yaml` (clair, temporaire) puis chiffrer avec sops.

### 6.3 Backup pré-wipe (le snapshot est notre seule source de rollback)

```bash
ssh -i ~/.ssh/id_vps20260131 root@72.62.239.98 \
  "tar czf /tmp/snapshot-$(date +%Y%m%d).tgz \
     /opt/trinity-lifeos/data \
     /opt/buck-writer-app/data \
     /opt/buck-writer-app/.env \
     /opt/trinity-lifeos/vps/docker/.env \
     /opt/trinity-lifeos/vps/docker/caddy/Caddyfile"

scp -i ~/.ssh/id_vps20260131 \
    root@72.62.239.98:/tmp/snapshot-*.tgz \
    ~/Backups/vps-pre-migration/
```

### 6.4 Wipe Docker

```bash
ssh root@VPS "
  docker compose -f /opt/trinity-lifeos/vps/docker/docker-compose.yml down -v
  docker compose -f /opt/buck-writer-app/vps/compose.yml down -v
  docker system prune -af --volumes
  docker network prune -f
"
```

### 6.5 Bootstrap script `bootstrap-vps.sh` (idempotent)

```bash
#!/bin/bash
set -euo pipefail

# 1. Pré-requis système
command -v docker >/dev/null || apt install -y docker.io docker-compose-plugin
command -v age >/dev/null    || apt install -y age
if ! command -v sops >/dev/null; then
  # sops n'est pas dans apt Debian/Ubuntu stable — binaire GitHub officiel
  SOPS_VERSION="v3.9.4"
  curl -sSL "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.amd64" \
    -o /usr/local/bin/sops
  chmod +x /usr/local/bin/sops
fi

# 2. Structure /opt/
mkdir -p /opt/_infra /opt/_data /opt/_backups

# 3. Clé age VPS (premier run uniquement)
mkdir -p /root/.config/sops/age
if [ ! -f /root/.config/sops/age/keys.txt ]; then
  age-keygen -o /root/.config/sops/age/keys.txt
  echo "VPS public key:"
  grep '# public key' /root/.config/sops/age/keys.txt
  echo ">>> Ajoute cette clé dans .sops.yaml local + re-chiffre les secrets <<<"
  exit 0
fi

# 4. Réseau Docker partagé
docker network create traefik-public 2>/dev/null || true

# 5. ACME storage (permissions strictes obligatoires)
mkdir -p /opt/_infra/data
touch /opt/_infra/data/acme.json
chmod 600 /opt/_infra/data/acme.json
```

**Premier run** : génère la clé age VPS, affiche la clé publique, s'arrête. Romain copie cette clé dans `.sops.yaml` localement, re-chiffre `secrets.enc.yaml`, push, pull sur le VPS.

**Runs suivants** : idempotent, ne fait que vérifier l'état.

### 6.6 Premier démarrage Traefik

Sur le VPS, dans `/opt/_infra/` :

```bash
./scripts/start.sh
```

Le script :
1. `sops -d secrets.enc.yaml` → exporte `CF_DNS_API_TOKEN` etc. en variables d'env temporaires
2. `docker compose up -d`
3. `docker compose logs -f traefik` → vérifier que ACME staging répond OK
4. Bascule en LE prod : éditer `traefik.yml` (commenter le `caServer` staging), `rm data/acme.json`, restart
5. Vérification : `curl -vI https://traefik.apps.romain-ecarnot.com` → cert LE valide

### 6.7 DNS Cloudflare

Records `A` à créer (mode DNS only, pas de proxy orange) :

- `apps.romain-ecarnot.com` → `72.62.239.98`
- `*.apps.romain-ecarnot.com` → `72.62.239.98`
- `*.buck.apps.romain-ecarnot.com` → `72.62.239.98` (pour les sous-niveaux Bible)

→ Une fois Traefik up + DNS propagé, n'importe quel `<n>.apps.romain-ecarnot.com` déclaré via labels Docker est servi automatiquement avec cert valide.

## 7. Configuration Traefik

### 7.1 `docker-compose.yml`

```yaml
networks:
  traefik-public:
    external: true
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
      - "traefik.http.services.status.loadbalancer.server.port=3001"
```

### 7.2 `traefik/traefik.yml`

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
      # Premier boot : staging actif (limite haute, certs auto-signés navigateur)
      caServer: https://acme-staging-v02.api.letsencrypt.org/directory
      # Après validation : commenter le staging ci-dessus, décommenter prod ci-dessous,
      # rm data/acme.json, redémarrer Traefik
      # caServer: https://acme-v02.api.letsencrypt.org/directory
      dnsChallenge:
        provider: cloudflare
        resolvers:
          - "1.1.1.1:53"
          - "8.8.8.8:53"
        delayBeforeCheck: 30
```

### 7.3 `traefik/dynamic/middlewares.yml`

```yaml
http:
  middlewares:
    dashboard-auth:
      basicAuth:
        usersFile: /dynamic/.htpasswd-dashboard

    security-headers:
      headers:
        frameDeny: true
        contentTypeNosniff: true
        browserXssFilter: true
        referrerPolicy: "strict-origin-when-cross-origin"
        stsSeconds: 31536000
        stsIncludeSubdomains: true
        stsPreload: true

    api-ratelimit:
      rateLimit:
        average: 100
        burst: 50

    redirect-www:
      redirectRegex:
        regex: "^https://www\\.(.+)"
        replacement: "https://${1}"
        permanent: true
```

### 7.4 `traefik/dynamic/tls.yml`

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

### 7.5 Modèle de labels qu'un projet appliquera (référence)

```yaml
buck-app:
  labels:
    - "traefik.enable=true"
    - "traefik.http.routers.buck.rule=Host(`buck.apps.romain-ecarnot.com`)"
    - "traefik.http.routers.buck.entrypoints=websecure"
    - "traefik.http.routers.buck.tls.certresolver=acme-cloudflare"
    - "traefik.http.routers.buck.middlewares=security-headers@file"
    - "traefik.http.services.buck.loadbalancer.server.port=3000"
  networks:
    - traefik-public
    - buck-internal
```

## 8. Cutover (basculement de l'existant)

Le cutover applicatif n'est pas exécuté pendant `infra-bootstrap` mais documenté ici pour anticipation. Il sera réalisé dans le sous-projet `migration-trinity-buck`.

### 8.1 Plan

```
T-1 jour   ─ A records *.apps.romain-ecarnot.com créés (TTL 60s)
T-1h       ─ Snapshot pré-wipe (§ 6.3) + push tous les commits projets
T0         ─ Wipe Docker (§ 6.4) + bootstrap _infra/ (§ 6.5-6.6)
            ─ Validation : curl https://traefik.apps.romain-ecarnot.com
            ─ Validation : curl https://status.apps.romain-ecarnot.com
T+15min    ─ Restore /opt/_data/n8n/ depuis snapshot
            ─ Up n8n avec labels Traefik vers n8n.apps.romain-ecarnot.com
            ─ Validation : login n8n, workflows présents
T+1h       ─ Buck pareil : restore data, deploy avec labels
            ─ Validation : login magic-link, créer doc, MCP Bible
T+1 jour   ─ Si stable : retirer anciens A records
            ─ Garder redirect 301 trinity.* → n8n.apps.* pendant 1 mois
```

### 8.2 Rollback

Le snapshot tarball de § 6.3 contient tout ce qu'il faut pour remonter l'ancienne stack :

```bash
ssh root@VPS
cd /opt/_infra && docker compose down
tar xzf ~/snapshot-YYYYMMDD.tgz -C /
cd /opt/trinity-lifeos/vps/docker && docker compose up -d
cd /opt/buck-writer-app/vps && docker compose up -d
# Re-bascule des DNS dans Cloudflare (les anciens A records existent toujours en T0)
```

→ Rollback complet en ~10 min si on suit le plan. Le nerf de la guerre = ne pas supprimer les anciens DNS records avant T+1 jour.

### 8.3 Risques identifiés et mitigations

| Risque | Probabilité | Mitigation |
|---|---|---|
| Rate limit LE atteint | Moyen | Démarrage en staging puis switch prod |
| Token Cloudflare mal scopé | Faible | Test curl pré-bootstrap (PDF § 5.1) |
| Volumes data corrompus au restore | Faible | Tarball local + verification `docker compose logs` au restart |
| Clé age VPS perdue | Faible mais bloquant | Backup de `/root/.config/sops/age/keys.txt` dans 1Password (manuel) |
| Trinity/Buck tournent encore + Traefik prend 80/443 | Moyen | Wipe Docker = étape obligatoire AVANT bootstrap _infra |
| Cloudflare proxy "orange cloud" activé | Faible | DNS records créés en mode DNS only (gris) explicitement |
| Voice-agent Trinity exposé sans auth pendant la transition | Élevé (déjà actif) | Action préalable : éteindre voice-agent (task gerber dédiée) |

## 9. Out of scope (sous-projets séparés)

- ❌ CLI `vps deploy/rollback/logs/prune` → `vps-cli`
- ❌ TUI dashboard → `vps-tui`
- ❌ Template GitHub Actions build → push GHCR → `ci-template`
- ❌ Migration concrète de Buck et Trinity vers le nouveau modèle de labels → `migration-trinity-buck`
- ❌ Dashboard web custom → `dashboard-web`

## 10. Critères d'acceptation

- [ ] `bootstrap-vps.sh` exécuté avec succès sur le VPS, idempotent (rejouable sans erreur)
- [ ] `docker network ls` montre `traefik-public`
- [ ] Stack `_infra` up : `docker compose ps` affiche `traefik` et `uptime-kuma` healthy
- [ ] `https://traefik.apps.romain-ecarnot.com` répond 401 sans auth, 200 avec basicauth, cert LE valide
- [ ] `https://status.apps.romain-ecarnot.com` répond 200, cert LE valide, Uptime Kuma initialisé
- [ ] Alerte Telegram configurée et testée (down forcé d'un service factice → notification reçue)
- [ ] Backup `acme.json` automatisé via `scripts/backup-acme.sh` (cron daily sur VPS)
- [x] ~~Trinity et Buck (anciens) toujours fonctionnels en parallèle~~ — **déplacé vers `migration-trinity-buck`** (Romain a validé un wipe complet du Docker existant en pré-bootstrap, ce critère n'a donc pas de sens dans `infra-bootstrap`)
- [ ] Spec et template commités dans `vps-docker-manager` (public)
- [ ] `vps-docker-manager-prod` créé en privé sur GitHub avec premier déploiement
- [ ] README documente la procédure complète
