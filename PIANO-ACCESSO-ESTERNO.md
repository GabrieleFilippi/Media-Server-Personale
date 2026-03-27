# Piano: Accesso Esterno a Jellyfin

> Piano concordato tra Claude (Opus 4.6) e Codex (GPT-5.3) dopo 4 round di confronto critico.
> Data: 2026-03-27

## Approccio Scelto: Hybrid (C)

- **Caddy** reverse proxy pubblico per Jellyfin (HTTPS automatico, Let's Encrypt)
- **Tailscale** per accesso remoto admin (Radarr, Sonarr, ecc.)
- Nessuna esposizione pubblica dei servizi di backend

### Perche' non le altre opzioni

| Approccio | Motivo esclusione |
|---|---|
| Solo Tailscale (B) | Friction su smart TV/media device; limite 3 utenti tailnet (sharing parziale workaround) |
| Solo Caddy+DDNS (A) | Non copre accesso admin remoto sicuro |
| Cloudflare Tunnel (D) | ToS Cloudflare vietano streaming video su tier free/pro — rischio enforcement |

---

## Prerequisiti da verificare PRIMA di iniziare

- [ ] **CGNAT**: verificare con ISP se l'IP pubblico e' reale o dietro CGNAT. Se CGNAT, il port-forward non funziona e serve VPN/tunnel alternativo
- [ ] **UPnP/NAT-PMP**: disabilitare sul router per evitare che container aprano porte autonomamente
- [ ] **Dominio**: acquistare un dominio economico (~2-3 EUR/anno) OPPURE registrare un hostname su DuckDNS. Un dominio proprio e' raccomandato (UX migliore, portabilita', trust)
- [ ] **Accesso router**: confermare accesso al pannello admin per port-forwarding

---

## Fasi di Implementazione

### Fase 0 — Preflight (sequenziale, prerequisito)

| Task | Descrizione | Note |
|---|---|---|
| 0.1 | Verifica CGNAT | `curl ifconfig.me` e confrontare con IP WAN del router |
| 0.2 | Disabilita UPnP sul router | Pannello admin router |
| 0.3 | Acquisto dominio o setup DuckDNS | Se dominio: configurare DNS A record. Se DuckDNS: registrare subdomain |
| 0.4 | Setup DDNS updater | Se IP dinamico: cron job o container `ddclient`/`duckdns` per aggiornare il record DNS |
| 0.5 | Mini threat model (vedi sezione dedicata) | Documento leggero, non enterprise |

---

### Fase 1 — Integrazione Compose (parallelizzabile parzialmente)

Questa fase modifica `docker-compose.yml`. I chunk 1A-1C sono accoppiati (stesso file, stesse dipendenze di rete) e vanno eseguiti come **un unico changeset atomico**. Il chunk 1D e' indipendente.

#### Chunk 1A+1B+1C: Reti, Porte, Caddy (un unico changeset)

**Segmentazione reti Docker:**
```yaml
networks:
  public:        # Caddy + Jellyfin
    name: mediaserver-public
    driver: bridge
  private:       # Tutto il backend
    name: mediaserver-private
    driver: bridge
```

- **Jellyfin**: SOLO rete `public` (raggiungibile da Caddy, NON sulla rete private)
- **Radarr, Sonarr, Prowlarr, qBittorrent, FlareSolverr**: SOLO rete `private`
- Jellyfin non ha bisogno di comunicare con i backend (legge solo volumi montati in read-only)

**Hardening porte — modello di accesso admin:**

> **Attenzione**: bindare le porte admin su `127.0.0.1` le rende irraggiungibili anche via Tailscale
> (Tailscale usa l'interfaccia `tailscale0`, non loopback). Due opzioni:
>
> **Opzione A (consigliata per semplicita'):** bindare i servizi admin sull'IP Tailscale del server
> usando una variabile `.env` (es. `TAILSCALE_IP=100.x.x.x`), poi fare firewall deny su tutto
> tranne `tailscale0` per quelle porte.
>
> **Opzione B:** tenere `127.0.0.1` e usare `tailscale ssh` + port-forward locale
> (`ssh -L 7878:127.0.0.1:7878`) — piu' sicuro ma meno comodo.

Con Opzione A:
- Radarr: `${TAILSCALE_IP}:7878:7878`
- Sonarr: `${TAILSCALE_IP}:8989:8989`
- Prowlarr: `${TAILSCALE_IP}:9696:9696`
- qBittorrent: `${TAILSCALE_IP}:8080:8080`
- FlareSolverr: rimuovere la porta esposta (usato solo internamente sulla rete `private`)
- Jellyfin: rimuovere `ports` (accesso solo via Caddy)

**Aggiunta Caddy:**
```yaml
caddy:
  image: caddy:2-alpine
  container_name: caddy
  ports:
    - "80:80"      # Necessario per ACME HTTP challenge
    - "443:443"
    - "443:443/udp" # HTTP/3 QUIC
  volumes:
    - ./Caddyfile:/etc/caddy/Caddyfile:ro
    - ${CONFIG_DIR}/caddy/data:/data      # Certificati TLS persistenti
    - ${CONFIG_DIR}/caddy/config:/config
    - ${CONFIG_DIR}/caddy/logs:/var/log/caddy  # Per fail2ban
  restart: unless-stopped
  networks:
    - public
```

**Caddyfile minimale:**
```caddyfile
jellyfin.tuodominio.com {
    reverse_proxy jellyfin:8096

    log {
        output file /var/log/caddy/access.log
    }
}
```
> Caddy v2 gestisce WebSocket automaticamente — nessuna config extra necessaria.

#### Chunk 1D: Healthchecks (indipendente)

Aggiungere healthcheck a tutti i servizi:
```yaml
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:PORT/ping"]
  interval: 30s
  timeout: 10s
  retries: 3
```
E aggiornare `depends_on` con `condition: service_healthy`.

---

### Fase 2 — Hardening Pre-Esposizione (sequenziale: Tailscale -> Firewall -> fail2ban)

> Ordine critico: Tailscale PRIMA del firewall per evitare lockout admin.

| Task | Descrizione | Dettagli |
|---|---|---|
| 2.1 | Installare Tailscale sul server | `curl -fsSL https://tailscale.com/install.sh \| sh` + `tailscale up` |
| 2.2 | Verificare accesso admin via Tailscale | Accedere a `http://100.x.x.x:7878` (Radarr) dal device Tailscale |
| 2.3 | Configurare firewall (nftables/ufw) | Default deny ingress; allow: 80/443 (Caddy), 22 (SSH), interfaccia `tailscale0` per porte admin. **Se si pubblica AAAA (IPv6)**: replicare le stesse regole per IPv6, oppure rimuovere il record AAAA per evitare bypass delle regole IPv4 |
| 2.4 | Setup fail2ban | **Prima fase**: jail solo su log Caddy (IP client reali garantiti). **Seconda fase**: jail su log Jellyfin solo DOPO aver configurato Known Proxies (task 3.2), altrimenti Jellyfin logga l'IP del proxy, non del client |

---

### Fase 3 — Esposizione + Configurazione App (sequenziale)

| Task | Descrizione | Dettagli |
|---|---|---|
| 3.1 | Port-forward sul router | 80 + 443 -> IP server (Caddy) |
| 3.2 | Configurare Jellyfin: Known Proxies | Aggiungere IP/subnet della rete Docker `public` nelle impostazioni di rete Jellyfin |
| 3.3 | Configurare `JELLYFIN_PublishedServerUrl` | Impostare al dominio pubblico (`https://jellyfin.tuodominio.com`) |
| 3.4 | Abilitare remote access in Jellyfin | Dashboard > Networking > Allow remote connections |
| 3.5 | Limiti bitrate per utente | Impostare bitrate massimo per connessioni remote (evita saturazione upload) |
| 3.6 | Politiche transcoding | Configurare limiti transcoding HW/SW in base alle capacita' del server |
| 3.7 | Test da rete esterna | Verificare con smartphone su 4G/5G — direct play + forced transcode |
| 3.8 | Test client compatibility | Verificare su tutti i device degli utenti reali (app Jellyfin mobile, web browser, TV) |

---

### Fase 4 — Miglioramenti Futuri (documentati, non implementati)

| Miglioramento | Quando ha senso |
|---|---|
| CrowdSec al posto di fail2ban | Se si vogliono threat intelligence feed condivisi |
| SSO / auth esterna (Authelia/Authentik) | Se si aggiungono altri servizi pubblici |
| Backup automatici config | Cron + restic/borg verso storage remoto |
| Monitoring (Uptime Kuma) | Per alerting se Jellyfin va giu' |
| Pin versioni immagini Docker | Sostituire `:latest` con tag specifici |
| HTTPS per admin via Tailscale | Tailscale HTTPS con certificati MagicDNS |

---

## Mini Threat Model

| Asset | Minaccia | Controllo |
|---|---|---|
| Jellyfin (pubblico) | Bot scanner / brute-force login | TLS (Caddy), auth Jellyfin, fail2ban, rate limit |
| Jellyfin (pubblico) | Credential stuffing | Password forti, fail2ban, limite tentativi |
| Servizi admin (LAN) | Pivot da device IoT compromesso | Porte su 127.0.0.1, rete Docker separata |
| Servizi admin (remoto) | Accesso non autorizzato | Solo via Tailscale (no porte pubbliche) |
| Upload bandwidth | Saturazione da transcoding | Limiti bitrate per utente, politiche transcode |
| Certificati TLS | Perdita / mancato rinnovo | Volumi persistenti Caddy, auto-renewal Let's Encrypt |
| Config servizi | Perdita dati | Backup periodici (Fase 4) |

---

## Struttura Branch

```
main (stabile, stack attuale funzionante)
  └── feature/external-access
        ├── Fase 1: compose changes (reti, porte, Caddy, healthchecks)
        ├── Fase 2: hardening config files
        ├── Fase 3: Jellyfin config + test
        └── merge → main quando validato
```

---

## Note Tecniche

- **CGNAT**: se presente, il port-forward non funziona. Alternative: VPN tunnel (es. WireGuard su VPS economico) o Tailscale Funnel
- **Caddy auto-HTTPS**: richiede porte 80 E 443 aperte per HTTP challenge. Alternativa: DNS challenge (necessita API del provider DNS)
- **Jellyfin WebSocket**: Caddy v2 fa proxy WebSocket automaticamente, nessuna config speciale
- **Jellyfin Base URL**: usare un sottodominio (`jellyfin.example.com`) NON un subpath (`example.com/jellyfin`) — i subpath rompono alcuni client
- **DuckDNS + Caddy**: Caddy supporta DuckDNS via plugin `caddy-dns/duckdns` per DNS challenge (utile se non si vuole aprire porta 80)
- **Persistenza Caddy**: i volumi `/data` e `/config` DEVONO essere persistenti — contengono certificati TLS e stato ACME. Senza persistenza, ogni restart richiede nuova emissione certificato (rate limit Let's Encrypt: 5 duplicati/settimana)
- **IPv6**: se il dominio ha un record AAAA, le regole firewall devono coprire anche IPv6 o il record va rimosso. Altrimenti un attaccante puo' bypassare le regole IPv4 connettendosi via IPv6
- **Tailscale + 127.0.0.1**: le porte bindate su loopback NON sono raggiungibili via Tailscale. Usare il bind sull'IP Tailscale + firewall, oppure SSH port-forward (vedi Fase 1 per dettagli)
