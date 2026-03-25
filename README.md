# Media Server Personale

Stack Docker self-hosted per scaricare e guardare film e serie TV da un portale web stile Netflix sulla tua rete locale. 100% gratuito e open source.

## Componenti

| Servizio | Porta | Funzione |
|---|---|---|
| Jellyfin | 8096 | Portale web stile Netflix |
| Radarr | 7878 | Automazione film |
| Sonarr | 8989 | Automazione serie TV |
| Prowlarr | 9696 | Gestione indexer torrent |
| qBittorrent | 8080 | Client torrent |
| FlareSolverr | 8191 | Bypass Cloudflare |

## Prerequisiti

- Docker e Docker Compose installati
- Un disco o partizione dedicata per i media (consigliato)
- Porte 8096, 7878, 8989, 9696, 8080, 8191 libere

## Installazione

### 1. Clona il repository

```bash
git clone <URL_REPO> && cd <NOME_REPO>
```

### 2. Configura le variabili d'ambiente

```bash
cp .env.example .env
nano .env
```

Modifica `MEDIA_ROOT` con il percorso del tuo disco dedicato (es. `/mnt/media`).
Verifica `PUID` e `PGID` con il comando `id`.

### 3. Crea le directory per i media

```bash
source .env
sudo mkdir -p "$MEDIA_ROOT"/{downloads,movies,tv}
sudo chown -R $PUID:$PGID "$MEDIA_ROOT"
```

### 4. Avvia lo stack

```bash
docker compose up -d
```

Verifica che tutti i container siano attivi:

```bash
docker compose ps
```

## Configurazione post-avvio

Segui questi passaggi **nell'ordine indicato** dopo il primo avvio.

### Step 1: Prowlarr (http://localhost:9696)

1. Al primo accesso, crea le credenziali di autenticazione
2. Vai in **Settings > Indexers** e aggiungi FlareSolverr come proxy:
   - Tag: `flaresolverr`
   - Host: `http://flaresolverr:8191`
3. Vai in **Indexers > Add Indexer** e aggiungi gli indexer che preferisci (es. 1337x, The Pirate Bay, EZTV, Torrentz2)
   - Per gli indexer protetti da Cloudflare, assegna il tag `flaresolverr`
4. Vai in **Settings > Apps** e aggiungi Radarr e Sonarr:
   - **Radarr**: Prowlarr Server = `http://prowlarr:9696`, Radarr Server = `http://radarr:7878`, API Key = (copiala da Radarr > Settings > General)
   - **Sonarr**: Prowlarr Server = `http://prowlarr:9696`, Sonarr Server = `http://sonarr:8989`, API Key = (copiala da Sonarr > Settings > General)

### Step 2: qBittorrent (http://localhost:8080)

1. La password iniziale e' generata automaticamente. Trovata nei log:
   ```bash
   docker logs qbittorrent 2>&1 | grep "temporary password"
   ```
2. Username: `admin`, password: quella dai log
3. Vai in **Options > Downloads**:
   - Default Save Path: `/downloads`
4. Vai in **Options > Web UI**:
   - Cambia la password con una a tua scelta

### Step 3: Radarr (http://localhost:7878)

1. Al primo accesso, configura l'autenticazione
2. Vai in **Settings > Media Management**:
   - Clicca **Add Root Folder**: `/movies`
3. Vai in **Settings > Download Clients > Add**:
   - Tipo: qBittorrent
   - Host: `qbittorrent`
   - Port: `8080`
   - Username: `admin`
   - Password: quella impostata al punto precedente
   - Clicca **Test** poi **Save**
4. Gli indexer si sincronizzano automaticamente da Prowlarr

Per aggiungere un film: **Movies > Add New** e cerca il titolo.

### Step 4: Sonarr (http://localhost:8989)

1. Al primo accesso, configura l'autenticazione
2. Vai in **Settings > Media Management**:
   - Clicca **Add Root Folder**: `/tv`
3. Vai in **Settings > Download Clients > Add**:
   - Tipo: qBittorrent
   - Host: `qbittorrent`
   - Port: `8080`
   - Username: `admin`
   - Password: quella impostata per qBittorrent
   - Clicca **Test** poi **Save**
4. Gli indexer si sincronizzano automaticamente da Prowlarr

Per aggiungere una serie: **Series > Add New** e cerca il titolo.

### Step 5: Jellyfin (http://localhost:8096)

1. Segui il wizard iniziale:
   - Crea un utente admin
   - Lingua preferita: Italiano
2. Aggiungi le librerie:
   - **Film**: tipo "Movies", cartella `/media/movies`
   - **Serie TV**: tipo "Shows", cartella `/media/tv`
3. Configura metadata:
   - Lingua: Italian
   - Paese: Italy

Jellyfin e' ora accessibile da qualsiasi dispositivo sulla tua rete locale all'indirizzo `http://<IP-SERVER>:8096`.

## Comandi utili

```bash
# Avvia tutto
docker compose up -d

# Ferma tutto
docker compose down

# Vedi i log di un servizio
docker compose logs -f jellyfin

# Aggiorna tutte le immagini
docker compose pull && docker compose up -d

# Stato dei container
docker compose ps
```

## Struttura directory

```
<MEDIA_ROOT>/
  downloads/    # File scaricati da qBittorrent (temporanei)
  movies/       # Film organizzati da Radarr
  tv/           # Serie TV organizzate da Sonarr

./config/       # Configurazioni persistenti dei servizi (gitignored)
  jellyfin/
  radarr/
  sonarr/
  prowlarr/
  qbittorrent/
```
