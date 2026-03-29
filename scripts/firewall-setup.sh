#!/bin/bash
# firewall-setup.sh — applica regole nftables per il media server
#
# PREREQUISITI:
#   1. Tailscale deve essere installato e attivo: l'interfaccia tailscale0 deve
#      esistere prima di applicare queste regole.
#      Avviare con: sudo systemctl start tailscaled && sudo tailscale up
#   2. Docker deve essere in esecuzione prima di applicare le regole.
#      Docker gestisce le proprie chain iptables (DOCKER, DOCKER-USER, NAT) —
#      questo script NON le tocca.
#
# COMPORTAMENTO CON DOCKER:
#   Docker su Arch Linux usa iptables-nft come backend.
#   Crea le proprie chain nella tabella "ip filter" di iptables.
#   Questo script usa una tabella nft separata ("inet mediaserver") per non
#   interferire con Docker. NON viene fatto flush del ruleset globale.
#
#   IMPORTANTE: i container possono interrogare il resolver dell'host tramite
#   il bridge Docker (tipicamente docker0 -> 172.17.0.1:53), specialmente
#   durante i build. Con una policy input=drop bisogna permettere DNS dal
#   bridge Docker verso l'host, altrimenti build/pull possono fallire per
#   timeout DNS.
#
#   IMPORTANTE: la chain "forward" con policy drop NON viene usata perche'
#   interferirebbe con il forwarding Docker dei container. Il traffico verso
#   i container e' filtrato da Docker tramite la chain DOCKER-USER (iptables).
#
# IDEMPOTENZA:
#   Lo script elimina e ricrea solo la tabella "inet mediaserver",
#   lasciando intatte le tabelle Docker e quelle di sistema.
#
# PERSISTENZA (scegli uno dei due metodi):
#
#   Metodo A — tramite /etc/nftables.conf (consigliato su Arch):
#     Dopo aver eseguito lo script, salva le sole regole mediaserver:
#       sudo nft list table inet mediaserver | sudo tee /etc/nftables.conf
#     Aggiungi in cima al file: #!/usr/sbin/nft -f
#     Abilita il servizio (assicurati che parta dopo tailscaled):
#       sudo systemctl enable nftables
#     Override per dipendenza tailscaled:
#       sudo mkdir -p /etc/systemd/system/nftables.service.d/
#       echo -e "[Unit]\nAfter=tailscaled.service" | \
#         sudo tee /etc/systemd/system/nftables.service.d/tailscale.conf
#
#   Metodo B — systemd service dedicato:
#     Crea /etc/systemd/system/firewall-mediaserver.service:
#       [Unit]
#       Description=Firewall mediaserver (nftables)
#       After=network.target tailscaled.service docker.service
#       Wants=tailscaled.service
#       [Service]
#       Type=oneshot
#       RemainAfterExit=yes
#       ExecStart=/usr/bin/bash /home/gabbo/MediaServer/scripts/firewall-setup.sh
#       ExecStop=/usr/sbin/nft delete table inet mediaserver
#       [Install]
#       WantedBy=multi-user.target
#     Poi: sudo systemctl daemon-reload && sudo systemctl enable --now firewall-mediaserver

set -euo pipefail

# ---------------------------------------------------------------------------
# Leggi HTTPS_PORT da .env (default: 443)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HTTPS_PORT=443
if [[ -f "${SCRIPT_DIR}/../.env" ]]; then
    while IFS='=' read -r key value; do
        [[ -z "${key}" || "${key}" =~ ^[[:space:]]*# ]] && continue
        key="${key// /}"
        case "${key}" in
            HTTPS_PORT) HTTPS_PORT="${value}" ;;
        esac
    done < "${SCRIPT_DIR}/../.env"
fi

# Verifica che tailscale0 esista; avverte ma non blocca
if ! ip link show tailscale0 &>/dev/null; then
    echo "ATTENZIONE: interfaccia tailscale0 non trovata." >&2
    echo "  Assicurati che Tailscale sia installato e attivo prima di applicare" >&2
    echo "  queste regole, oppure riapplica lo script dopo 'tailscale up'." >&2
    echo "  Continuo comunque con l'applicazione delle regole..." >&2
fi

echo "Porta HTTPS configurata: ${HTTPS_PORT}"
echo "Applicazione regole nftables (tabella inet mediaserver)..."

# Rimuovi solo la tabella mediaserver se esiste, senza toccare le tabelle Docker
nft delete table inet mediaserver 2>/dev/null || true

nft -f - <<NFTABLES
# ============================================================
# Tabella inet mediaserver — traffico host (IPv4 + IPv6)
#
# Questa tabella gestisce SOLO il traffico INPUT verso l'host.
# Il forwarding verso i container Docker e' gestito interamente
# da Docker tramite iptables-nft (chain DOCKER, DOCKER-USER, NAT).
# NON definiamo una chain "forward" qui per non interferire.
# ============================================================
table inet mediaserver {

    # ----------------------------------------------------------
    # INPUT — traffico destinato all'host
    # Policy: DROP (nega tutto cio' che non e' esplicitamente permesso)
    # ----------------------------------------------------------
    chain input {
        type filter hook input priority 0; policy drop;

        # Loopback: sempre permesso
        iifname "lo" accept comment "loopback"

        # Connessioni gia' stabilite o correlate (risposte a connessioni uscenti)
        ct state established,related accept comment "conntrack established/related"

        # Connessioni non valide: scarta esplicitamente
        ct state invalid drop comment "conntrack invalid"

        # Docker bridge -> host DNS
        # Necessario per consentire ai container (e ai build xcaddy/go) di
        # risolvere nomi via il resolver dell'host su 172.17.0.1:53.
        iifname "docker0" udp dport 53 accept comment "Docker bridge DNS UDP"
        iifname "docker0" tcp dport 53 accept comment "Docker bridge DNS TCP"

        # SSH — accesso da qualsiasi IP
        # Per limitare solo a Tailscale sostituire con:
        #   iifname "tailscale0" tcp dport 22 accept
        tcp dport 22 accept comment "SSH"

        # HTTPS — per Caddy (reverse proxy pubblico di Jellyfin)
        # Porta configurabile via HTTPS_PORT in .env (default 443, usa 41443 per iliadbox)
        tcp dport ${HTTPS_PORT} accept comment "HTTPS Caddy (porta ${HTTPS_PORT})"
        udp dport ${HTTPS_PORT} accept comment "HTTPS/QUIC Caddy (porta ${HTTPS_PORT})"

        # Tailscale — tutto il traffico sull'interfaccia VPN
        # Permette accesso ai servizi admin (Radarr, Sonarr, ecc.) via Tailscale
        iifname "tailscale0" accept comment "Tailscale VPN"

        # BitTorrent peer (qBittorrent) — porte 6881 TCP e UDP
        tcp dport 6881 accept comment "qBittorrent peer TCP"
        udp dport 6881 accept comment "qBittorrent peer UDP"

        # ICMP — permetti ping per diagnostica
        ip protocol icmp accept comment "ICMP ping IPv4"
        ip6 nexthdr icmpv6 accept comment "ICMPv6 ping IPv6"
    }

    # ----------------------------------------------------------
    # OUTPUT — traffico originato dall'host
    # Policy: ACCEPT (nessuna restrizione sul traffico uscente)
    # ----------------------------------------------------------
    chain output {
        type filter hook output priority 0; policy accept;
    }

    # NOTA: chain "forward" non definita intenzionalmente.
    # Docker gestisce il forwarding dei container tramite iptables-nft.
    # Definire una chain forward con policy drop qui bloccherebbe i container.
}
NFTABLES

echo "Regole nftables applicate con successo."
echo ""
echo "Ruleset tabella mediaserver:"
nft list table inet mediaserver
