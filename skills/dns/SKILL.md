---
name: dns
description: Pre-flight DNS check Cloudflare avant deploy. Verifie que <app>.${VPS_APPS_DOMAIN} (et sous-domaines) resout vers l'IP VPS (${VPS_HOST#*@}). Utilise dig + Cloudflare API pour confirmer A record + propagation. Detecte le gotcha F9 (DNS pas propage = Traefik renvoie 404). Triggers : "check DNS <app>", "verifier DNS avant deploy", "dns prod", "/deploy-vps:dns".
---

# dns <app>

Verifie la configuration DNS d'une app avant deploy. Lecture pure.

VPS IP cible : `${VPS_HOST#*@}`. Zone Cloudflare : `${VPS_APPS_DOMAIN}`.

## Args

- `app` (obligatoire) : nom court (`buck`, `n8n`, `trinity`).

## Workflow

### Etape 1 — Determiner les domaines a check

```bash
cd ${VPS_ORCHESTRATOR_PATH}

# Domaine principal
DOMAIN="${APP}.${VPS_APPS_DOMAIN}"

# Sous-domaines (extrait du compose.yml du repo app si present)
COMPOSE="../${APP}*/deploy-vps/compose.yml"
SUBDOMAINS=$(grep -hoE 'Host\(`[^`]+`\)' $COMPOSE 2>/dev/null \
  | sed -E 's/Host\(`([^`]+)`\)/\1/' | sort -u)
```

Si pas de compose accessible, demander manuellement les sous-domaines a l'utilisateur (ou skip).

### Etape 2 — Resolution DNS publique (dig)

Pour chaque domaine :

```bash
RESOLVED=$(dig +short A "$DOMAIN" @1.1.1.1)
```

- Si vide -> NXDOMAIN ou pas encore propage.
- Si != `${VPS_HOST#*@}` -> mauvaise IP cible.
- Si == `${VPS_HOST#*@}` -> OK.

Tester aussi via plusieurs resolveurs (1.1.1.1, 8.8.8.8, 9.9.9.9) pour detecter une propagation partielle.

### Etape 3 — Cross-check Cloudflare API (optionnel)

Si `CLOUDFLARE_API_TOKEN` dispo dans l'env :

```bash
ZONE_ID=$(curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones?name=${VPS_APPS_DOMAIN}" \
  | jq -r '.result[0].id')

curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$DOMAIN" \
  | jq '.result[] | {type, name, content, proxied, ttl}'
```

Permet de detecter :
- Record absent cote Cloudflare (alors que DNS public dit autre chose -> cache stale).
- Proxied=true (Cloudflare proxy actif -> l'IP visible publiquement n'est PAS celle du VPS, c'est normal mais il faut le savoir).

### Etape 4 — Rapport

```markdown
## DNS check pour buck

| Domaine | Resolveur | A record | Verdict |
|---|---|---|---|
| buck.${VPS_APPS_DOMAIN} | 1.1.1.1 | ${VPS_HOST#*@} | OK |
| buck.${VPS_APPS_DOMAIN} | 8.8.8.8 | ${VPS_HOST#*@} | OK |
| bible.buck.${VPS_APPS_DOMAIN} | 1.1.1.1 | NXDOMAIN | MISSING |

Verdict global : DEGRADED (1/3 domaines manquant)

Action suggeree :
- Ajouter un A record pour bible.buck.${VPS_APPS_DOMAIN} -> ${VPS_HOST#*@} dans Cloudflare
- Attendre 1-5 min de propagation
- Re-run dns check
```

## Restrictions

- Lecture pure : aucune modification Cloudflare. Si un record manque, l'utilisateur doit l'ajouter manuellement (UI Cloudflare ou API + token write).
- Si Cloudflare proxy=true, l'IP retournee par `dig` sera une IP Cloudflare (104.x.x.x ou 172.x.x.x). Ce n'est PAS un probleme — Traefik recoit quand meme le traffic. Mais signaler dans le rapport.
- Gotcha F9 : si DNS resout vers la bonne IP mais que Traefik renvoie 404, c'est probablement le router config (label `traefik.http.routers.<app>.rule=Host(...)` mal formate ou app pas en service `traefik-public` network). Suggerer la skill `deploy-doctor` dans ce cas.
