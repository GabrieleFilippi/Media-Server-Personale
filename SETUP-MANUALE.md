# Guida Setup Manuale — Accesso Esterno Jellyfin

> Questo documento descrive i passi che devi eseguire manualmente.
> Gli script nella cartella `scripts/` automatizzano tutto il resto.

---

## Prima di iniziare — Verifica CGNAT

Questo è il check più importante. Se sei dietro CGNAT il port-forwarding non funzionerà.

```bash
curl ifconfig.me
```

Confrontalo con l'IP WAN mostrato nel pannello del tuo router.

- **Coincidono** → procedi pure
- **Non coincidono** (IP WAN del router in range `100.64.x.x`, `10.x.x.x`, `192.168.x.x`) → sei dietro CGNAT. Opzioni:
  - Chiedi all'ISP un IP pubblico dedicato (spesso gratuito su richiesta)
  - Usa solo Tailscale per tutti gli utenti (nessun accesso HTTP pubblico)
  - VPS economico + WireGuard come tunnel

---

## Passo 1 — Prerequisiti di sistema

```bash
sudo pacman -S docker fail2ban nftables bind curl
sudo systemctl enable --now docker
sudo systemctl enable --now fail2ban
sudo usermod -aG docker $USER
# Esci e rientra nella sessione per applicare il gruppo docker
```

**Verifica:**
```bash
docker compose version && fail2ban-client version && nft --version
```

---

## Passo 2 — Installa Tailscale

> Deve essere fatto **prima** di applicare il firewall, altrimenti rischi il lockout admin.

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo systemctl enable --now tailscaled
sudo tailscale up
# Segui il link per autenticarti nel browser
tailscale ip -4
# Annota questo IP: ti serve come TAILSCALE_IP nel .env
```

**Verifica:** da un altro device con Tailscale, apri `http://<TAILSCALE_IP>:7878` (Radarr) — deve rispondere dopo aver avviato lo stack.

---

## Passo 3 — Dominio / DDNS

### Opzione A: dominio proprio (consigliato)
Acquista un dominio (~2–3 €/anno su Porkbun, Namecheap, ecc.) e usa Cloudflare come nameserver (API DDNS gratuita). Crea un record `A` che punta al tuo IP pubblico.

### Opzione B: DuckDNS (gratuito)
1. Vai su [duckdns.org](https://www.duckdns.org) e accedi con Google/GitHub
2. Crea un sottodominio (es. `mionome.duckdns.org`)
3. Annota il token mostrato nella pagina

---

## Passo 4 — Configura il file .env

```bash
cp .env.example .env
nano .env
```

| Variabile | Valore |
|---|---|
| `MEDIA_ROOT` | Path al disco media (es. `/mnt/media`) |
| `PUID` / `PGID` | Output di `id -u` e `id -g` |
| `TZ` | Timezone (es. `Europe/Rome`) |
| `TAILSCALE_IP` | IP Tailscale del server (`tailscale ip -4`) |
| `DOMAIN` | Il tuo dominio o sottodominio DuckDNS |

---

## Passo 5 — Configura DDNS updater

```bash
bash scripts/generate-ddclient-conf.sh
# Script interattivo: sceglie provider e raccoglie credenziali
```

Avvia il container:
```bash
docker compose --profile ddns up -d ddclient
docker compose logs -f ddclient
# Attendi qualche secondo — deve mostrare "SUCCESS" o "nochange"
```

**Verifica:**
```bash
dig +short A tuodominio.com
# Deve restituire il tuo IP pubblico
```

---

## Passo 6 — Disabilita UPnP sul router

Accedi al pannello del router (solitamente `192.168.1.1`) e disabilita:
- UPnP (Universal Plug and Play)
- NAT-PMP

Mentre sei nel pannello, trova anche la sezione **Port Forwarding** — ti servirà al Passo 9.

---

## Passo 7 — Esegui il check prerequisiti

```bash
bash scripts/preflight.sh
```

Risolvi tutti i `FAIL` prima di continuare. Output atteso alla fine:
```
  Riepilogo: N OK  |  N WARN  |  0 FAIL
```

---

## Passo 8 — Applica il firewall

> Tailscale deve essere attivo (Passo 2 completato).

```bash
sudo bash scripts/firewall-setup.sh
sudo nft list table inet mediaserver  # verifica
```

**Rendi persistente** (scegli un metodo):

**Metodo A — nftables.conf:**
```bash
sudo bash scripts/firewall-setup.sh
sudo nft list table inet mediaserver | sudo tee /etc/nftables.conf
sudo sed -i '1s/^/#!/usr\/sbin\/nft -f\n/' /etc/nftables.conf
sudo systemctl enable nftables
sudo mkdir -p /etc/systemd/system/nftables.service.d/
echo -e "[Unit]\nAfter=tailscaled.service" | \
  sudo tee /etc/systemd/system/nftables.service.d/tailscale.conf
sudo systemctl daemon-reload
```

**Metodo B — systemd service dedicato:**
```bash
sudo tee /etc/systemd/system/firewall-mediaserver.service <<'EOF'
[Unit]
Description=Firewall mediaserver (nftables)
After=network.target tailscaled.service docker.service
Wants=tailscaled.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/home/gabbo/MediaServer/scripts/firewall-setup.sh
ExecStop=/usr/sbin/nft delete table inet mediaserver
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now firewall-mediaserver
```

---

## Passo 9 — Port-forward sul router

Nel pannello del router aggiungi due regole di port-forwarding verso l'IP LAN del server:

| Porta esterna | Porta interna | Protocollo |
|---|---|---|
| 80 | 80 | TCP |
| 443 | 443 | TCP |

**Verifica** (da smartphone con WiFi spento, solo dati mobili):
```
http://tuodominio.com
```
Deve reindirizzare su HTTPS. Se vedi la pagina Jellyfin o un errore 502 di Caddy, il port-forward funziona.

---

## Passo 10 — Avvia lo stack

```bash
docker compose up -d
docker compose ps
# Attendi che tutti i container siano "healthy" (1–2 minuti)
```

Se qualche container non parte:
```bash
docker compose logs <nome-servizio>
```

---

## Passo 11 — Configura Jellyfin: Known Proxies e accesso remoto

1. Apri Jellyfin via Tailscale: `http://<TAILSCALE_IP>:8096`
2. **Dashboard → Networking**
3. Trova la subnet Docker della rete pubblica:
   ```bash
   docker network inspect mediaserver-public | grep -A3 '"Subnet"'
   # Es: 172.18.0.0/16
   ```
4. Inserisci quella subnet nel campo **"Known Proxies"** e salva
5. Abilita **"Allow remote connections"**
6. Imposta il **limite di bitrate remoto** (consigliato: 20–40 Mbps in base al tuo upload)

---

## Passo 12 — Installa fail2ban

```bash
sudo bash scripts/deploy-fail2ban.sh
sudo fail2ban-client status caddy-auth
# Deve mostrare: Currently banned: 0
```

**Test filtro** (opzionale ma consigliato):
```bash
# Sostituisci il path con il valore assoluto di CONFIG_DIR
sudo fail2ban-regex \
  /path/assoluto/config/caddy/logs/access.log \
  /etc/fail2ban/filter.d/caddy.conf \
  --print-all-matched
```

---

## Passo 13 — Abilita jail Jellyfin

Solo dopo aver completato il Passo 11 (Known Proxies configurato):

```bash
sudo nano /etc/fail2ban/jail.d/mediaserver.conf
# Sezione [jellyfin-auth]: cambia  enabled = false  →  enabled = true
sudo fail2ban-client reload
sudo fail2ban-client status jellyfin-auth
```

---

## Passo 14 — Test finale

Da smartphone con WiFi spento (solo dati mobili):

1. Apri `https://tuodominio.com` — lucchetto verde, pagina Jellyfin
2. Fai login
3. Avvia un video — verifica direct play
4. Forza il transcoding dalle impostazioni player — verifica che funzioni

---

## Riepilogo script

| Script | Quando usarlo |
|---|---|
| `bash scripts/preflight.sh` | Prima di tutto, per verificare i prerequisiti |
| `sudo bash scripts/firewall-setup.sh` | Per applicare/riapplicare le regole nftables |
| `bash scripts/deploy-fail2ban.sh` | Per installare/aggiornare i config fail2ban |
| `bash scripts/generate-ddclient-conf.sh` | Per generare la config DDNS (una volta sola) |
