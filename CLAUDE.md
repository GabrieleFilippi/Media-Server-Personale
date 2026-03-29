# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Self-hosted Docker media server stack for downloading and streaming movies/TV shows via a Netflix-like web portal, accessible both on LAN and externally via HTTPS. All services run as Docker containers across two bridge networks (`mediaserver-public` for Caddy+Jellyfin, `mediaserver-private` for the acquisition backend).

## Architecture

The stack has two layers:

**Public (rete `mediaserver-public`)**
```
Internet → Caddy (reverse proxy, :${HTTPS_PORT:-443}, DNS-01 TLS via DuckDNS)
              └── Jellyfin (streaming UI, porta non esposta direttamente)
```

**Private (rete `mediaserver-private`, accessibile solo via Tailscale)**
```
Radarr (movie automation, :7878) + Sonarr (TV automation, :8989)
  └── qBittorrent (torrent client, :8080) + Prowlarr (indexer manager, :9696)
        └── FlareSolverr (Cloudflare bypass, non esposto)
```

- **Prowlarr** syncs indexers to Radarr/Sonarr automatically via their APIs
- **Radarr/Sonarr** send downloads to qBittorrent, then hard-link/move completed files to media directories
- **Jellyfin** mounts media directories as read-only

## Key Files

- `docker-compose.yml` — defines all 7 services, their volumes, ports, and dependencies
- `Caddyfile` — configurazione Caddy reverse proxy (dominio, TLS DNS-01, header sicurezza, log)
- `caddy/Dockerfile` — custom Caddy build con plugin DuckDNS per DNS-01 challenge
- `.env.example` — template for environment config (copy to `.env`)
- `.env` — actual config (gitignored): sets `MEDIA_ROOT`, `PUID`/`PGID`, `TZ`, `CONFIG_DIR`, `TAILSCALE_IP`, `DOMAIN`, `HTTPS_PORT`, `DUCKDNS_API_TOKEN`

## Common Commands

```bash
docker compose up -d          # Start all services
docker compose down            # Stop all services
docker compose ps              # Check container status
docker compose logs -f <svc>   # Tail logs for a service (caddy, jellyfin, radarr, sonarr, prowlarr, qbittorrent, flaresolverr)
docker compose up -d --build                   # Rebuild (Caddy custom) and start
docker compose pull && docker compose up -d    # Update all images
```

## Volume Layout

All media paths derive from `MEDIA_ROOT` (set in `.env`):
- `${MEDIA_ROOT}/downloads` — qBittorrent download dir, shared with Radarr/Sonarr
- `${MEDIA_ROOT}/movies` — Radarr-managed film library, mounted read-only in Jellyfin at `/media/movies`
- `${MEDIA_ROOT}/tv` — Sonarr-managed TV library, mounted read-only in Jellyfin at `/media/tv`
- `./config/<service>/` — persistent config for each service (gitignored)

## Inter-Service Communication

Containers comunicano via service name Docker sulla loro rete:
- Rete `mediaserver-public`: Caddy → `http://jellyfin:8096`
- Rete `mediaserver-private`: Radarr/Sonarr → `http://qbittorrent:8080`, `http://prowlarr:9696`, `http://flaresolverr:8191`

Usare sempre i container name come hostname, mai `localhost`. Admin services (Radarr, Sonarr, Prowlarr, qBittorrent) sono esposti solo sull'IP Tailscale (`TAILSCALE_IP`).

## DNS Override

Prowlarr, FlareSolverr, and qBittorrent use custom DNS (1.1.1.1, 8.8.8.8) in docker-compose.yml to bypass Italian ISP DNS blocking of torrent sites. Do not remove these entries.

## Language Preference

Radarr and Sonarr have a Custom Format "Italian" with score +1000 on the "Any" quality profile. This prefers Italian releases but falls back to original language. The profile language is set to "Any" (not restricted).

## Configured Indexers (in Prowlarr)

6 indexers: 1337x, EZTV, The Pirate Bay, YTS, LimeTorrents, ilCorSaRoNeRo. Italian indexers have priority 10 (higher than international at 25). FlareSolverr tag is assigned to Cloudflare-protected indexers (1337x, ilCorSaRoNeRo).
