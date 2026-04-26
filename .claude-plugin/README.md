# hostinger plugin

Plugin Claude Code pour le pattern deploy-vps multi-apps : tag-driven release pipeline (GHCR + sops + Traefik) sur un VPS unique.

## Variables d'environnement requises

Ce plugin lit les valeurs sensibles (IP VPS, domaine, path orchestrateur) depuis l'environnement shell. Ajoute dans `~/.zshenv` (ou `~/.bashrc`) :

```bash
export VPS_HOST="root@<your-vps-ip>"
export VPS_APPS_DOMAIN="<your-apps-subdomain>"
export VPS_ORCHESTRATOR_PATH="$HOME/dev/<orchestrator-repo>"
```

| Variable | Description | Exemple |
|---|---|---|
| `VPS_HOST` | Cible SSH `user@ip` du VPS | `root@1.2.3.4` |
| `VPS_APPS_DOMAIN` | Zone DNS pour les sous-domaines apps | `apps.example.com` |
| `VPS_ORCHESTRATOR_PATH` | Path local du repo orchestrateur (avec compose templates et secrets sops) | `~/dev/my-orchestrator` |

Toute skill/agent qui en a besoin fait un fail explicite avec `${VAR:?Set VAR in ~/.zshenv}` si la variable n'est pas definie.

## Skills

- `bootstrap` — Onboard une nouvelle app dans le pattern
- `deploy` — Tag + push + watch pipeline GA
- `rollback` — Rollback via UI GA (chemin A) ou SSH (chemin B)
- `status` — Snapshot containers + healthcheck (read-only)
- `logs` — Tail Docker logs
- `secret-rotate` — Edit/rotate secrets sops (input silencieux)
- `dns` — Pre-flight DNS check Cloudflare

## Agents

- `deploy-doctor` — Diagnostic read-only d'une app en panne
- `deploy-clean` — Menage VPS (docker prune, dossiers obsoletes)
- `update-checker` — Verifier nouvelles versions Docker images upstream

## Pre-requis

- SSH cle configuree pour `$VPS_HOST` (sans passphrase ou agent unlocked).
- Repo orchestrateur clone localement avec `sops`, `age` keys, `gh` CLI.
- Cloudflare zone configuree pour `$VPS_APPS_DOMAIN` (skill `dns`).
