# Guida Setup Manuale — Accesso Esterno Jellyfin

> Questa guida parte da **stack locale già funzionante**. Non ripete il setup base.
> Copre solo il delta necessario per esporre Jellyfin su Internet.

---

## 1. Verifica fattibilità WAN (CGNAT)

**Perché:** Se sei dietro CGNAT il port-forwarding non funziona e tutto il resto è inutile. Va verificato prima di qualsiasi altra cosa.

```bash
curl ifconfig.me
```

Confronta con l'IP WAN nel pannello del router.

| Risultato | Significato | Cosa fare |
|---|---|---|
| Coincidono | IP pubblico dedicato | Procedi |
| Non coincidono | Sei dietro CGNAT | Chiama ISP e chiedi IP pubblico, oppure usa solo Tailscale per tutti |

---

## 2. Router: IP statico + UPnP off

**Perché — IP statico:** il port-forward punta a un IP LAN specifico. Se il server cambia IP dopo un reboot (DHCP lease scaduto), il forward punta nel vuoto e l'accesso esterno si rompe senza motivo apparente.

**Perché — UPnP off:** UPnP permette a qualsiasi software sulla LAN di aprire porte sul router senza il tuo consenso. In uno stack esposto su Internet è un rischio inaccettabile.

Nel pannello del router:
1. Assegna un **IP statico** (DHCP reservation) al MAC address del server
2. Disabilita **UPnP** e **NAT-PMP**

---

## 3. DNS e dominio

**Perché:** Caddy ha bisogno di un dominio per emettere il certificato TLS. Non funziona con un IP numerico.

### Opzione A: dominio proprio (consigliato, ~2–3 €/anno)
Acquista su Porkbun/Namecheap, usa **Cloudflare come nameserver**. Crea un record `A` con il tuo IP pubblico.

> **Attenzione Cloudflare:** il record deve essere **DNS only** (nuvola grigia, proxy OFF). Se lasci il proxy arancione attivo, Cloudflare fa da CDN e i suoi ToS vietano lo streaming video su tier gratuito.

> **IPv6:** se il tuo provider DNS crea automaticamente un record `AAAA`, rimuovilo oppure replica le stesse regole firewall per IPv6. Altrimenti un attaccante può bypassare le tue regole IPv4 connettendosi via IPv6.

### Opzione B: DuckDNS (gratuito)
1. [duckdns.org](https://www.duckdns.org) → accedi → crea sottodominio
2. Annota il token

### DDNS (solo se IP dinamico)
Se il tuo IP pubblico cambia periodicamente, configura l'aggiornamento automatico:

```bash
bash scripts/generate-ddclient-conf.sh    # interattivo: sceglie provider, raccoglie credenziali
docker compose --profile ddns up -d ddclient
```

**Verifica:** `dig +short A tuodominio.com` deve restituire il tuo IP pubblico.

Se hai IP statico, il DDNS non serve — salta questo sotto-passo.

---

## 4. Tailscale

**Perché:** I servizi admin (Radarr, Sonarr, Prowlarr, qBittorrent) sono esposti solo sull'IP Tailscale — senza Tailscale non riesci a gestirli da remoto e nemmeno da LAN dopo il firewall. Va installato **prima** del firewall: se fai il contrario, `tailscale0` non esiste quando il firewall si applica e perdi accesso admin.

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo systemctl enable --now tailscaled
sudo tailscale up        # segui il link nel browser
tailscale ip -4          # annota l'IP — ti serve al passo 5
```

---

## 5. Aggiorna .env e preflight

**Perché:** Il `.env` esiste già ma manca le due variabili nuove. Lo script di preflight verifica tutto il necessario prima di procedere con i passi irreversibili.

Aggiungi al tuo `.env` solo le variabili nuove:

```bash
# Aggiungi queste righe (i valori reali, non i placeholder)
TAILSCALE_IP=<output di tailscale ip -4>
DOMAIN=<il tuo dominio dal passo 3>

# HTTPS su porta alta (workaround iliadbox — vedi passo 7)
HTTPS_PORT=41443
DUCKDNS_API_TOKEN=<il tuo token da duckdns.org>
```

Poi verifica:
```bash
bash scripts/preflight.sh
```

Risolvi tutti i `FAIL` prima di continuare.

---

## 6. Firewall

**Perché:** Il server attualmente accetta connessioni su tutte le porte. Dopo l'esposizione su Internet deve passare solo: SSH, HTTPS su porta alta (Caddy), Tailscale (admin), e 6881 (BitTorrent). Tutto il resto viene droppato. Lo script legge `HTTPS_PORT` dal `.env` automaticamente.

```bash
sudo pacman -S nftables    # se non già installato
sudo bash scripts/firewall-setup.sh
```

Rendi persistente al reboot (metodo consigliato):
```bash
sudo tee /etc/systemd/system/firewall-mediaserver.service <<'EOF'
[Unit]
Description=Firewall mediaserver (nftables)
After=network.target tailscaled.service docker.service
Wants=tailscaled.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/bash /home/gabbo/MediaServer/scripts/firewall-setup.sh
ExecStop=/usr/sbin/nft delete table inet mediaserver
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now firewall-mediaserver
```

---

## 7. Port-forward e riavvio stack

**Perché — port-forward:** il router deve sapere dove mandare le connessioni HTTPS in arrivo. Caddy usa il challenge DNS-01 (via API DuckDNS) per emettere il certificato Let's Encrypt, quindi **la porta 80 non è necessaria**.

> **Nota iliadbox:** il router iliadbox permette port-forwarding solo su porte > 40960. Per questo usiamo la porta 41443 (configurabile in `.env` come `HTTPS_PORT`). Caddy ottiene il certificato TLS tramite DNS-01 challenge, che non richiede porte in ingresso.

Nel pannello del router, aggiungi:

| Porta | Protocollo | Destinazione |
|---|---|---|
| 41443 | TCP | IP LAN del server |
| 41443 | UDP | IP LAN del server (opzionale, per HTTP/3 QUIC) |

Poi riavvia lo stack (il primo avvio compila l'immagine Caddy custom con il plugin DuckDNS):
```bash
docker compose down && docker compose up -d --build
docker compose ps    # attendi healthy su tutti i container
```

Al primo avvio Caddy emette il certificato TLS automaticamente via DNS-01. Se fallisce, controlla `docker compose logs caddy` — tipicamente è un problema di token DuckDNS o DNS che non risolve.

> **Revert a porta standard:** se in futuro ottieni IPv4 Full Stack da Iliad, rimuovi `HTTPS_PORT` dal `.env`, rimuovi il blocco globale `{ ... }` dal `Caddyfile`, e cambia il port-forward a 443. Caddy tornerà automaticamente a usare HTTP-01 challenge su porta standard.

---

## 8. Jellyfin + fail2ban + test

Tre sotto-passi in sequenza rigorosa. L'ordine conta.

### 8A. Known Proxies e accesso remoto

**Perché:** Senza Known Proxies, Jellyfin vede l'IP di Caddy (es. `172.18.0.2`) in ogni richiesta invece dell'IP reale del client. Conseguenza: log inutili e fail2ban che banna Caddy stesso (= blocca tutti).

1. Apri `https://<DOMAIN>:41443` e fai login come admin → **Dashboard → Networking**
   > In questo stack Jellyfin non espone `8096` sull'host/Tailscale: l'accesso passa da Caddy sulla porta configurata in `HTTPS_PORT`.
2. Trova la subnet di Caddy:
   ```bash
   docker network inspect mediaserver-public --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'
   ```
3. Incolla nel campo **Known Proxies** e salva
4. Abilita **Allow remote connections**
5. Imposta il **bitrate remoto** (suggerito: 20–40 Mbps in base al tuo upload)

### 8B. Deploy fail2ban

**Perché:** Protegge da brute-force automatico. La jail Caddy si abilita subito (gli IP nei log sono già reali). La jail Jellyfin si abilita solo dopo 8A.

```bash
sudo pacman -S fail2ban    # se non già installato
sudo systemctl enable --now fail2ban
sudo bash scripts/deploy-fail2ban.sh
```

Lo script sostituisce i placeholder, valida, installa e ricarica. Poi abilita la jail Jellyfin:

```bash
sudo sed -i '/^\[jellyfin-auth\]/,/^enabled/ s/enabled  = false/enabled  = true/' /etc/fail2ban/jail.d/mediaserver.conf
sudo fail2ban-client reload
sudo fail2ban-client status    # deve mostrare caddy-auth e jellyfin-auth attive
```

### 8C. Test end-to-end

**Perché:** L'unica verifica reale è da rete esterna. Un test da LAN bypassa router e firewall.

Da smartphone (WiFi spento, solo dati mobili):

1. `https://tuodominio.com:41443` — lucchetto verde
2. Login
3. Avvia un video — direct play
4. Forza transcoding — deve funzionare

---

## Troubleshooting

| Problema | Diagnosi | Fix |
|---|---|---|
| `https://dominio` non risponde | `dig +short A dominio` — se non risolve: DNS/DDNS non configurato. Se risolve ma non risponde: port-forward sbagliato o CGNAT | Verifica DNS, poi verifica port-forward nel router |
| Caddy non emette il certificato (DNS-01) | `docker compose logs caddy` — cerca errori "dns" o "acme". Tipico: token DuckDNS sbagliato o scaduto | Verifica `DUCKDNS_API_TOKEN` in `.env`. Test manuale: `curl "https://www.duckdns.org/update?domains=gabbojellyfin&token=TOKEN&txt=test"` — deve rispondere "OK" |
| Jellyfin risponde ma 502 | Caddy raggiunge Jellyfin? `docker compose logs caddy` + `docker compose ps jellyfin` | Verifica che Jellyfin sia healthy e sulla rete `public` |
| Banned da fail2ban per errore | `sudo fail2ban-client set caddy-auth unbanip <tuo-ip>` | Per emergenze: `sudo fail2ban-client stop` |
| Lockout firewall (SSH non risponde) | Accesso fisico alla macchina, poi: `sudo nft delete table inet mediaserver` | Rimuove il firewall, poi riesegui `firewall-setup.sh` dopo aver corretto |
| Admin (Radarr/Sonarr) non raggiungibili via Tailscale | `tailscale status` — sei connesso? `curl http://<TAILSCALE_IP>:7878` | Verifica che `TAILSCALE_IP` nel `.env` corrisponda a `tailscale ip -4` |
| DDNS non aggiorna l'IP | `docker compose logs ddclient` — cerca errori auth | Token/zona/subdomain sbagliati nel config. Rigenera con `generate-ddclient-conf.sh` |
| Cloudflare: certificato Caddy fallisce | Record DNS in modalità proxy (nuvola arancione) | Cambia in **DNS only** (nuvola grigia) nel dashboard Cloudflare |

---

## Script disponibili

| Script | Cosa fa |
|---|---|
| `bash scripts/preflight.sh` | Verifica prerequisiti (env, servizi, porte, DNS) |
| `sudo bash scripts/firewall-setup.sh` | Applica regole nftables |
| `sudo bash scripts/deploy-fail2ban.sh` | Installa config fail2ban con path reali |
| `bash scripts/generate-ddclient-conf.sh` | Genera config DDNS interattivamente |
