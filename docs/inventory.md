# Inventaire VPS Hostinger — état actuel

Snapshot au 2026-04-25 avant réorganisation.

## VPS

| Item | Valeur |
|---|---|
| Provider | Hostinger |
| IP | `72.62.239.98` |
| User SSH | `root` |
| Clé SSH locale | `~/.ssh/id_vps20260131` |
| Domaine racine | `romain-ecarnot.com` |
| Reverse proxy | Caddy (hébergé par Trinity) |
| Network Docker partagé | `caddy-public` (external, créé manuellement) |

## Projets déployés

### 1. Trinity LifeOS Agent

- **Repo local** : `/Users/recarnot/dev/trinity-lifeos-agent`
- **Repo VPS** : `/opt/trinity-lifeos`
- **Stack** : Node 20 (Voice Agent), n8n, Qdrant, Caddy
- **Composes** : `vps/docker/docker-compose.yml` (prod) + `voice-agent/docker-compose.local.yml` (dev)
- **Domaines** : `trinity.romain-ecarnot.com` (n8n), `live.trinity.romain-ecarnot.com` (voice agent)
- **Stratégie de build** : build Docker en local AMD64 → `tar.gz` → `scp` vers VPS → `docker load`
- **Scripts** : `vps/deploy-and-update.sh`, `vps/docker/update.sh`, `vps/build-docker-vps.sh`
- **Secrets** : `.env` clair, pull_policy `never` (l'image doit être chargée avant `up`)
- **Auth** : voice-agent **sans auth** actuellement (plan basicauth écrit, non déployé)
- **CI** : aucune

### 2. Buck Writer App

- **Repo local** : `/Users/recarnot/dev/buck-writer-app`
- **Repo VPS** : `/opt/buck-writer-app`
- **Stack** : Node 20 + Hono, React 19/Vite, SQLite, Bible MCP, Writing-Tools MCP (Python), MarkItDown worker (Python), Supabase (memory)
- **Composes** : `vps/compose.yml` (prod, 5 services) + `vps/compose.local.yml` (dev hybride : MCPs Docker, app pnpm dev)
- **Domaines** : `buck.*`, `bible.buck.*`, `bible-mcp.buck.*`, `writing-mcp.buck.*`
- **Stratégie de build** : `git fetch + reset --hard` côté VPS → `docker compose build` côté VPS
- **Scripts** : `vps/deploy.sh` (8.9 KB, 8 étapes — touche aussi `/opt/trinity-lifeos`)
- **Secrets** : `.env.production` + `.env.trinity` SCP'd à chaque deploy ; `MCP_SHARED_SECRET` dupliqué dans les deux
- **Auth** : magic-link Buck, forward_auth Bible UI, Bearer Caddy MCPs
- **CI** : `.github/workflows/deploy-vps.yml` (tag `v*` ou manuel) + `security.yml` (audit hebdo)

## Couplages problématiques

1. **Buck ↔ Trinity** : `deploy.sh` Buck modifie `Caddyfile` et `.env` Trinity, puis force-recreate Caddy Trinity. Impossible de déployer Buck si Trinity est down.
2. **Caddyfile dupliqué** : la config Caddy vit dans le repo Buck (`vps/Caddyfile`) ET dans Trinity (`/opt/trinity-lifeos/caddy/Caddyfile`). Source de vérité = Buck.
3. **`MCP_SHARED_SECRET`** présent dans `.env.production` Buck **et** `.env.trinity` (doit matcher).
4. **`caddy-public` network** : créé à la main, référencé `external: true` partout. Pas documenté.
5. **Stratégies de build divergentes** : Trinity = build local + scp tar.gz (pull_policy never). Buck = git pull + build sur VPS. Pas de standard.
6. **Pas de registry** : aucun (Docker Hub, GHCR). Tout passe par scp ou rebuild VPS.
7. **Pas de stratégie backup** : `backup.sh` mentionné dans README Trinity mais inexistant dans le repo. SQLite Buck + n8n workflows en risque.

## Secrets / surface d'exposition

- 3 fichiers `.env` plaintext circulent par scp : `vps/.env.production` (Buck), `vps/.env.trinity` (Buck → Trinity), `vps/docker/.env` (Trinity).
- API keys exposées dans ces fichiers : `OPENAI_API_KEY`, `RESEND_API_KEY`, `GEMINI_API_KEY`, `GOOGLE_API_KEY`, `XAI_API_KEY`, `PICOVOICE_API_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `TRINITY_API_KEY`.
- Aucun secret manager (Vault, 1Password CLI, doppler, sops).
- Voice-agent Trinity exposé publiquement sans auth.

## Volumes / données critiques

| Projet | Volume | Contenu |
|---|---|---|
| Trinity | `data/n8n/` | Workflows + creds n8n |
| Trinity | `data/voice-memory/` | SQLite mémoire voice-agent |
| Trinity | `data/qdrant/` | Vector DB |
| Trinity | `data/caddy/` | Certs Let's Encrypt |
| Buck | `data/db/` | SQLite Buck |
| Buck | `data/workspace/` | Prompts/skills/attachments live |
| Buck | `data/bible/` | SQLite Bible MCP + embeddings |
