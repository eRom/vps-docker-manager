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
/opt/_infra/                        <- ce repo
/opt/_data/                         <- volumes apps (vide initialement)
/opt/_backups/                      <- snapshots data + acme.json
/root/.config/sops/age/keys.txt     <- cle age privee VPS
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
