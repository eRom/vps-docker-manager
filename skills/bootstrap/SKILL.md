---
name: bootstrap
description: Onboarde une nouvelle app dans le pattern deploy-vps multi-apps. Cree apps/<app>/deploy-state.yaml + secrets/<app>.enc.yaml chiffre sops cote vps-docker-manager-prod, et le squelette deploy-vps/compose.yml + .github/workflows/release.yml cote repo app. Workflow interactif. Triggers : "bootstrap <app>", "onboarder une nouvelle app", "ajouter une app au pattern deploy-vps", "/deploy-vps:bootstrap".
---

# bootstrap <app>

Onboarde une **nouvelle** app dans le pattern `deploy-vps`. Workflow interactif.

Repo orchestrateur : `${VPS_ORCHESTRATOR_PATH}` (eRom/vps-docker-manager-prod, prive). Sur GA : `${{ github.workspace }}`.

## Etape 0 — Pre-flight guards (fail-fast)

**AVANT toute action**, verifier qu'aucun artefact bootstrap n'existe deja. Si une seule de ces conditions est vraie, **STOPPER immediatement** et signaler a l'utilisateur :

```bash
cd ${VPS_ORCHESTRATOR_PATH}

# Guard 1 : state app cote orchestrateur
[ -d "apps/$APP" ] && abort "apps/$APP/ existe deja — app deja bootstrapee. Edite manuellement ou supprime d'abord."

# Guard 2 : secrets sops chiffre
[ -f "secrets/$APP.enc.yaml" ] && abort "secrets/$APP.enc.yaml existe deja — risque d'ecraser tes secrets prod. STOP."

# Guard 3 : entree README
grep -q "| $APP |" README.md && abort "$APP deja liste dans README.md. STOP."

# Guard 4 : compose dans le repo app
APP_REPO_LOCAL="${APP_REPO_LOCAL:-$HOME/dev/${APP_REPO##*/}}"
if [ -d "$APP_REPO_LOCAL" ]; then
  [ -f "$APP_REPO_LOCAL/deploy-vps/compose.yml" ] && abort "$APP_REPO_LOCAL/deploy-vps/compose.yml existe deja — risque d'ecraser ta config. STOP."
  [ -f "$APP_REPO_LOCAL/.github/workflows/release.yml" ] && abort "$APP_REPO_LOCAL/.github/workflows/release.yml existe deja. STOP."
fi
```

`abort` = afficher le message en rouge et `exit 1`. **Aucune option `--force`** : si l'utilisateur veut reconfigurer une app deja onboarded, il edite manuellement les fichiers concernes (ou utilisera une futur skill `reconfigure`).

Cette skill est **strictement pour onboarding initial**. Pour modifier une app existante :
- Changer un secret -> skill `secret-rotate`
- Changer le compose -> editer `<app-repo>/deploy-vps/compose.yml` directement
- Changer la version deployee -> skill `deploy` (nouveau tag)

## Workflow

### Etape 1 — Collecter les infos

Demander a l'utilisateur (une question a la fois) :

1. **`app`** : nom court de l'app, kebab-case (ex: `n8n`, `trinity`, `buck`).
2. **`app_repo`** : owner/name du repo app (ex: `eRom/n8n-stack`).
3. **`domain`** : domaine principal (ex: `n8n.${VPS_APPS_DOMAIN}`).
4. **`image`** : image Docker. Soit GHCR custom (`ghcr.io/erom/<app>:${TAG}`), soit officielle (`n8nio/n8n:latest`).
5. **`services`** : liste des services Docker du compose.
6. **`subdomains`** : sous-domaines additionnels (ex: pour Buck = `bible`, `bible-mcp`, `writing-mcp`). Optionnel.
7. **`auth_strategy`** : `traefik-basicauth` | `forward-auth` | `bearer-mcp` | `none`.

### Etape 2 — Creer l'arborescence cote vps-docker-manager-prod

```bash
cd ${VPS_ORCHESTRATOR_PATH}
mkdir -p apps/$APP

cat > apps/$APP/deploy-state.yaml <<EOF
app: $APP
app_repo: $APP_REPO
tag: null
version: null
sha: null
deployed_at: null
deployed_by: null
EOF
```

### Etape 3 — Creer le secrets sops chiffre

Template en clair pour edition immediate, puis chiffrage + shred :

```bash
cat > secrets/$APP.yaml <<EOF
# === $APP secrets ===
# TODO: ajoute tes secrets ici, puis sauve.
EXAMPLE_KEY: replace_me
EOF

$EDITOR secrets/$APP.yaml
sops -e secrets/$APP.yaml > secrets/$APP.enc.yaml
shred -u secrets/$APP.yaml
```

NE JAMAIS committer le secret en clair. Toujours `shred -u` apres chiffrement (defense en profondeur, pas de `rm`).

### Etape 4 — Mettre a jour le README.md du repo prod

Ajouter une ligne dans la table "Apps deployees" :

```markdown
| $APP | https://$DOMAIN | (jamais deploye) | - |
```

### Etape 5 — Generer le squelette dans le repo app

Cloner le repo app si pas deja en local. Puis creer :

**`<app-repo>/deploy-vps/compose.yml`** — labels Traefik standards :

```yaml
name: $APP

services:
  $APP:
    image: $IMAGE
    container_name: $APP
    restart: unless-stopped
    env_file: /opt/$APP/.env
    networks: [traefik-public, internal]
    labels:
      - traefik.enable=true
      - traefik.docker.network=traefik-public
      - traefik.http.routers.$APP.rule=Host(`$DOMAIN`)
      - traefik.http.routers.$APP.entrypoints=websecure
      - traefik.http.routers.$APP.tls.certresolver=acme-cloudflare
      - traefik.http.services.$APP.loadbalancer.server.port=3000

networks:
  traefik-public:
    external: true
  internal:
    driver: bridge
```

ATTENTION : la cle `name: $APP` au top-level est obligatoire (gotcha F13 — sans ca, Docker prefixe avec le nom du dossier et la skill `status` ne retrouve plus les containers).

**`<app-repo>/.github/workflows/release.yml`** : matrix GHCR + dispatch (calque sur `eRom/buck-writer-app/.github/workflows/release.yml` si build custom, sinon dispatch only pour les images officielles).

### Etape 6 — PAT scoped + secret repo app

Creer un PAT fine-grained (https://github.com/settings/personal-access-tokens/new) :

- Resource owner : `eRom`
- Repo access : Selected -> `vps-docker-manager-prod`
- Permissions : Contents = Read+Write, Actions = Read+Write
- Expiration : 1 an

Puis :

```bash
gh secret set INFRA_DISPATCH_PAT --repo $APP_REPO
```

### Etape 7 — Recipient age dans .sops.yaml

Si l'app a des contributeurs autres que Romain, demander leur cle age publique et l'ajouter dans `.sops.yaml` recipients du repo prod. Sinon, les 3 recipients par defaut (laptop + VPS + runner GA) suffisent.

### Etape 8 — Checklist post-bootstrap

Imprimer pour l'utilisateur :

```markdown
Bootstrap $APP termine.

Reste a faire (toi):
- [ ] DNS records Cloudflare pour $DOMAIN (A ${VPS_HOST#*@})
- [ ] Editer deploy-vps/compose.yml dans le repo app pour les vrais services
- [ ] Editer .github/workflows/release.yml pour la matrix d'images reelle
- [ ] Completer secrets/$APP.enc.yaml (sops $APP.enc.yaml)
- [ ] Premier tag : git tag $APP-v0.1.0-rc.1 && git push --tags
```

## Restrictions

- **Strictement onboarding initial** : si Etape 0 detecte n'importe quel artefact existant, ABORT. Pas d'option `--force`.
- NE JAMAIS committer le secret en clair (`secrets/$APP.yaml`).
- `shred -u` apres chiffrement, pas `rm`.
- Verifier l'IP VPS dans Cloudflare AVANT le premier deploy (skill `dns`).
