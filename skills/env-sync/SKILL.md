---
name: env-sync
description: Synchronise un fichier .env local (gitignored, valeurs en clair) vers le secrets sops chiffre <orchestrator>/secrets/<app>.enc.yaml. Pipe stream-only (zero fichier intermediaire en clair, zero leak dans la session Claude). Idempotent. Triggers : "sync env <app>", "envoie mon .env vers sops", "/hostinger:env-sync", "rotate keys depuis .env".
---

# env-sync <app> [path-to-.env]

Convertit ton `.env` local (au fil de l'eau pendant le dev) en `${VPS_ORCHESTRATOR_PATH}/secrets/<app>.enc.yaml` chiffre sops, sans jamais ecrire les valeurs en clair sur disk et sans qu'elles passent par la conversation Claude.

## Inputs

- `app` : nom court de l'app (ex: `buck`, `n8n`, `trinity`).
- `path-to-.env` (optionnel) : path absolu ou relatif. Defaut : `$HOME/dev/<app-repo>/.env` (l'utilisateur doit confirmer si la convention de nommage du repo differe de l'app).

## Workflow

### Etape 1 — Pre-flight

```bash
: "${VPS_ORCHESTRATOR_PATH:?Set VPS_ORCHESTRATOR_PATH in ~/.zshenv}"

[ -f "$ENV_FILE" ] || abort "Fichier $ENV_FILE introuvable."
[ -f "$VPS_ORCHESTRATOR_PATH/secrets/$APP.enc.yaml" ] || abort "secrets/$APP.enc.yaml inexistant — utilise la skill bootstrap d'abord."

command -v sops >/dev/null || abort "sops absent du PATH."
```

### Etape 2 — Sync via le script

Le script `scripts/env-to-sops.sh` (livre avec cette skill) fait le pipe stdin -> sops. Il ne logue jamais les valeurs, seulement les noms de keys.

```bash
PLUGIN_DIR="$(dirname "$0")"  # ou le path du plugin installe
"$PLUGIN_DIR/scripts/env-to-sops.sh" "$APP" "$ENV_FILE"
```

Le script :
1. Convertit `.env` en YAML key:value via `awk` (pipe stdin).
2. Pipe direct vers `sops --input-type yaml -e /dev/stdin`.
3. Ecrit le resultat chiffre dans `$VPS_ORCHESTRATOR_PATH/secrets/$APP.enc.yaml.tmp` puis `mv` atomique.
4. Affiche la liste des noms de keys synchronisees (PAS les valeurs).

### Etape 3 — Review du diff (chiffre)

```bash
cd "$VPS_ORCHESTRATOR_PATH"
git diff --stat secrets/$APP.enc.yaml
```

Le diff git est chiffre — tu verras juste un blob binaire change. C'est normal et c'est la garantie que rien ne fuit.

Pour comparer schema (noms de keys uniquement) avant/apres :

```bash
sops -d secrets/$APP.enc.yaml | yq 'keys' > /tmp/keys-after.$$
git show HEAD:secrets/$APP.enc.yaml | sops -d /dev/stdin | yq 'keys' > /tmp/keys-before.$$
diff /tmp/keys-before.$$ /tmp/keys-after.$$
shred -u /tmp/keys-before.$$ /tmp/keys-after.$$
```

### Etape 4 — Commit + redeploy

```bash
git add secrets/$APP.enc.yaml
git commit -m "chore(secrets/$APP): sync from .env"

# Optionnel : trigger redeploy si appli deja deployee
read -p "Redeploy $APP avec les nouveaux secrets ? [y/N] " ANSWER
if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
  echo "Lance la skill /hostinger:deploy ou push un tag."
fi
```

## Pattern .env.local (template)

Pour onboarder un nouveau dev (ou te rappeler quelles keys sont attendues), commit un `.env.local` dans le repo app avec **les noms de keys uniquement** et une valeur placeholder :

```bash
# .env.local (commite)
DATABASE_URL=__set_in_.env__
ANTHROPIC_API_KEY=__set_in_.env__
JWT_SECRET=__set_in_.env__
```

Detection des keys manquantes :

```bash
diff <(awk -F= '!/^(#|$)/{print $1}' .env | sort) \
     <(awk -F= '!/^(#|$)/{print $1}' .env.local | sort)
```

## Restrictions

- **Jamais de mktemp pour le YAML clair** : tout passe par stdin/stdout. Si la machine plante en plein script, rien ne reste sur disk.
- **Le script ne doit PAS etre invoque par Claude avec capture du stdout des valeurs**. Si tu dois debugger, run-le toi-meme dans ton terminal hors session.
- Les noms de keys sont visibles (logs, diff schema). Si un nom de key est lui-meme sensible (rare), edite a la main avec `sops secrets/$APP.enc.yaml`.
- Pas de support multi-environnement (dev/staging/prod). Cette skill suppose un seul `.env` source de verite par app.
