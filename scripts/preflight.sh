#!/bin/bash
# =============================================================================
# preflight.sh — Verifica prerequisiti prima di avviare lo stack con accesso esterno
# =============================================================================
#
# USO:
#   bash scripts/preflight.sh
#
# COSA FA:
#   Verifica tutti i prerequisiti necessari per l'accesso esterno sicuro:
#   variabili .env, comandi, servizi di sistema, networking, Docker, DNS.
#   Stampa OK / WARN / FAIL per ogni check e un riepilogo finale.
#
# EXIT CODE:
#   0 — tutti i check passano (anche con WARN)
#   1 — almeno un check FAIL
#
# NOTA: questo script NON richiede sudo.
# =============================================================================

# NON usare set -euo pipefail: i check devono continuare anche se uno fallisce

# ---------------------------------------------------------------------------
# Colori e contatori
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

COUNT_OK=0
COUNT_WARN=0
COUNT_FAIL=0

check_ok()   {
    echo -e "${GREEN}[OK]${NC}   $*"
    COUNT_OK=$((COUNT_OK + 1))
}
check_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
    COUNT_WARN=$((COUNT_WARN + 1))
}
check_fail() {
    echo -e "${RED}[FAIL]${NC} $*"
    COUNT_FAIL=$((COUNT_FAIL + 1))
}

section() {
    echo ""
    echo "── $* ──────────────────────────────────────────"
}

# ---------------------------------------------------------------------------
# Path del progetto
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

# Variabili .env (popolate più avanti se .env esiste)
TAILSCALE_IP=""
DOMAIN=""
CONFIG_DIR=""
HTTPS_PORT=""
DUCKDNS_API_TOKEN=""

# ---------------------------------------------------------------------------
# Sezione 1: Variabili .env
# ---------------------------------------------------------------------------
section "Variabili .env"

if [[ -f "${ENV_FILE}" ]]; then
    check_ok ".env trovato in ${PROJECT_ROOT}"
    # shellcheck disable=SC1090
    # Carica le variabili in modo sicuro (solo KEY=VALUE, no subshell pericolose)
    while IFS='=' read -r key value; do
        # Salta righe vuote e commenti
        [[ -z "${key}" || "${key}" =~ ^[[:space:]]*# ]] && continue
        key="${key// /}"
        case "${key}" in
            TAILSCALE_IP)      TAILSCALE_IP="${value}" ;;
            DOMAIN)            DOMAIN="${value}" ;;
            CONFIG_DIR)        CONFIG_DIR="${value}" ;;
            HTTPS_PORT)        HTTPS_PORT="${value}" ;;
            DUCKDNS_API_TOKEN) DUCKDNS_API_TOKEN="${value}" ;;
        esac
    done < "${ENV_FILE}"
else
    check_fail ".env non trovato — copia .env.example in .env e compila i valori"
fi

# TAILSCALE_IP
if [[ -z "${TAILSCALE_IP}" ]]; then
    check_fail "TAILSCALE_IP non settato in .env"
elif [[ "${TAILSCALE_IP}" == "100.x.x.x" ]]; then
    check_fail "TAILSCALE_IP è ancora il placeholder (100.x.x.x) — esegui: tailscale ip -4"
else
    check_ok "TAILSCALE_IP settato: ${TAILSCALE_IP}"
fi

# DOMAIN
if [[ -z "${DOMAIN}" ]]; then
    check_fail "DOMAIN non settato in .env"
elif [[ "${DOMAIN}" == "jellyfin.example.com" ]]; then
    check_fail "DOMAIN è ancora il placeholder (jellyfin.example.com) — imposta il tuo dominio reale"
else
    check_ok "DOMAIN settato: ${DOMAIN}"
fi

# DUCKDNS_API_TOKEN (obbligatorio se HTTPS_PORT non-standard)
if [[ -n "${HTTPS_PORT}" && "${HTTPS_PORT}" != "443" ]]; then
    if [[ -z "${DUCKDNS_API_TOKEN}" ]]; then
        check_fail "DUCKDNS_API_TOKEN non settato in .env — necessario per DNS-01 challenge con porta ${HTTPS_PORT}"
    else
        check_ok "DUCKDNS_API_TOKEN settato (DNS-01 challenge per porta ${HTTPS_PORT})"
    fi
fi

# CONFIG_DIR
if [[ -z "${CONFIG_DIR}" ]]; then
    check_fail "CONFIG_DIR non settato in .env"
else
    # Risolvi path relativo rispetto alla root del progetto
    CONFIG_DIR_ABS="${CONFIG_DIR}"
    if [[ "${CONFIG_DIR}" != /* ]]; then
        CONFIG_DIR_ABS="$(cd "${PROJECT_ROOT}" && realpath -m "${CONFIG_DIR}" 2>/dev/null || echo "")"
    fi
    if [[ -z "${CONFIG_DIR_ABS}" ]]; then
        check_fail "CONFIG_DIR non risolvibile: ${CONFIG_DIR}"
    elif [[ ! -d "${CONFIG_DIR_ABS}" ]]; then
        check_warn "CONFIG_DIR non esiste ancora: ${CONFIG_DIR_ABS} — verrà creata dai container al primo avvio"
    elif [[ ! -w "${CONFIG_DIR_ABS}" ]]; then
        check_fail "CONFIG_DIR non scrivibile: ${CONFIG_DIR_ABS} — correggi i permessi"
    else
        check_ok "CONFIG_DIR esiste e scrivibile: ${CONFIG_DIR_ABS}"
    fi
fi

# ---------------------------------------------------------------------------
# Sezione 2: Comandi richiesti
# ---------------------------------------------------------------------------
section "Comandi richiesti"

# docker
if command -v docker &>/dev/null; then
    if docker compose version &>/dev/null 2>&1; then
        check_ok "Docker installato e 'docker compose' funzionante"
    else
        check_warn "docker presente ma 'docker compose' non funziona — verifica il plugin Docker Compose"
    fi
else
    check_fail "docker non trovato — installa Docker: sudo pacman -S docker"
fi

# nft
if command -v nft &>/dev/null; then
    check_ok "nft (nftables) presente"
else
    check_fail "nft non trovato — installa nftables: sudo pacman -S nftables"
fi

# fail2ban-client
if command -v fail2ban-client &>/dev/null; then
    check_ok "fail2ban-client presente"
else
    check_fail "fail2ban-client non trovato — installa fail2ban: sudo pacman -S fail2ban"
fi

# tailscale
if command -v tailscale &>/dev/null; then
    check_ok "tailscale presente"
else
    check_warn "tailscale non trovato — installa Tailscale prima di applicare il firewall"
fi

# curl
if command -v curl &>/dev/null; then
    check_ok "curl presente"
else
    check_fail "curl non trovato — installa curl: sudo pacman -S curl"
fi

# dig
if command -v dig &>/dev/null; then
    check_ok "dig presente"
else
    check_warn "dig non trovato — installa bind-tools per i check DNS: sudo pacman -S bind"
fi

# ---------------------------------------------------------------------------
# Sezione 3: Servizi di sistema
# ---------------------------------------------------------------------------
section "Servizi di sistema"

for svc in docker tailscaled fail2ban; do
    if systemctl is-active --quiet "${svc}" 2>/dev/null; then
        check_ok "Servizio '${svc}' attivo"
    else
        if systemctl list-unit-files --quiet "${svc}.service" &>/dev/null 2>&1; then
            check_fail "Servizio '${svc}' non attivo — avvialo con: sudo systemctl start ${svc}"
        else
            check_warn "Servizio '${svc}' non trovato nel sistema"
        fi
    fi
done

# ---------------------------------------------------------------------------
# Sezione 4: Networking
# ---------------------------------------------------------------------------
section "Networking"

# Porta HTTPS configurata
CHECK_PORT="${HTTPS_PORT:-443}"
if command -v ss &>/dev/null; then
    if ss -tlnp 2>/dev/null | grep -qE ":${CHECK_PORT}\b"; then
        check_fail "Porta ${CHECK_PORT} già in uso — controlla con: ss -tlnp | grep :${CHECK_PORT}"
    else
        check_ok "Porta HTTPS ${CHECK_PORT} libera"
    fi
else
    check_warn "ss non disponibile — impossibile verificare porta ${CHECK_PORT}"
fi

# Interface tailscale0
if ip link show tailscale0 &>/dev/null 2>&1; then
    check_ok "Interfaccia tailscale0 presente"
else
    check_warn "tailscale0 non trovata — installa e avvia Tailscale prima di applicare il firewall"
fi

# IPv4 pubblico accessibile
PUBLIC_IPV4=""
if command -v curl &>/dev/null; then
    PUBLIC_IPV4="$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || true)"
    if [[ -n "${PUBLIC_IPV4}" ]]; then
        check_ok "IPv4 pubblico accessibile: ${PUBLIC_IPV4}"
    else
        check_warn "Impossibile recuperare l'IPv4 pubblico da ifconfig.me (timeout o nessuna connessione)"
    fi
else
    check_warn "curl non disponibile — impossibile verificare l'IPv4 pubblico"
fi

# Check CGNAT: confronta IP WAN del router con IPv4 pubblico
# Il gateway predefinito è presumibilmente il router
GATEWAY_IP=""
if command -v ip &>/dev/null; then
    GATEWAY_IP="$(ip route show default 2>/dev/null | awk '/default/ { print $3; exit }' || true)"
fi

if [[ -n "${PUBLIC_IPV4}" && -n "${GATEWAY_IP}" ]]; then
    # Recupera IP WAN del router (molti router espongono /status o simili — non standard)
    # Non possiamo farlo in modo affidabile via script generico: emetti WARN con istruzioni
    check_warn "Check CGNAT: verifica manuale richiesta."
    echo "         IPv4 pubblico rilevato: ${PUBLIC_IPV4}"
    echo "         Gateway locale:       ${GATEWAY_IP}"
    echo "         Accedi al pannello del router e verifica che l'IPv4 WAN corrisponda a ${PUBLIC_IPV4}."
    echo "         Se l'IP WAN del router è nel range 100.64.0.0/10 o 10.0.0.0/8 sei dietro CGNAT"
    echo "         e il port-forwarding non funzionerà — usa solo Tailscale per l'accesso esterno."
else
    check_warn "Check CGNAT impossibile da verificare automaticamente."
    echo "         Verifica manualmente: l'IPv4 WAN del router deve corrispondere all'IPv4 pubblico."
    echo "         Se sei dietro CGNAT il port-forwarding non funzionerà."
fi

# ---------------------------------------------------------------------------
# Sezione 5: Docker Compose
# ---------------------------------------------------------------------------
section "Docker Compose"

if command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
    if [[ -f "${ENV_FILE}" ]]; then
        compose_output="$(docker compose -f "${PROJECT_ROOT}/docker-compose.yml" \
            --env-file "${ENV_FILE}" config --quiet 2>&1)"
        compose_exit=$?
        if [[ ${compose_exit} -eq 0 ]]; then
            check_ok "docker compose config valido (nessun errore)"
        else
            check_fail "docker compose config ha errori:"
            echo "${compose_output}" | sed 's/^/         /'
        fi
    else
        check_warn "docker compose config non verificato — .env mancante"
    fi
else
    check_warn "docker compose config non verificato — docker non disponibile"
fi

# ---------------------------------------------------------------------------
# Sezione 6: DNS
# ---------------------------------------------------------------------------
section "DNS"

if [[ -n "${DOMAIN}" && "${DOMAIN}" != "jellyfin.example.com" ]]; then
    if command -v dig &>/dev/null; then
        DNS_RESULT="$(dig +short A "${DOMAIN}" 2>/dev/null | head -1 || true)"
        if [[ -n "${DNS_RESULT}" ]]; then
            check_ok "DNS: ${DOMAIN} risolve a ${DNS_RESULT}"
            if [[ -n "${PUBLIC_IPV4}" && "${DNS_RESULT}" != "${PUBLIC_IPV4}" ]]; then
                check_warn "DNS: ${DOMAIN} risolve a ${DNS_RESULT} ma l'IPv4 pubblico è ${PUBLIC_IPV4} — aggiorna il record DNS o il DDNS"
            fi
        else
            check_warn "DNS: ${DOMAIN} non risolve ancora — configura il record A o aspetta la propagazione DDNS"
        fi
    else
        check_warn "DNS: dig non disponibile — impossibile verificare la risoluzione di ${DOMAIN}"
    fi
else
    check_warn "DNS: DOMAIN non configurato o ancora placeholder — skip check DNS"
fi

# ---------------------------------------------------------------------------
# Riepilogo finale
# ---------------------------------------------------------------------------
echo ""
echo "══════════════════════════════════════════════════════"
echo "  Riepilogo: ${COUNT_OK} OK  |  ${COUNT_WARN} WARN  |  ${COUNT_FAIL} FAIL"
echo "══════════════════════════════════════════════════════"

if [[ ${COUNT_FAIL} -gt 0 ]]; then
    echo ""
    echo -e "${RED}Ci sono ${COUNT_FAIL} check FAIL — risolvi i problemi prima di procedere.${NC}"
    exit 1
elif [[ ${COUNT_WARN} -gt 0 ]]; then
    echo ""
    echo -e "${YELLOW}Ci sono ${COUNT_WARN} avvisi (WARN) — puoi procedere ma valuta le segnalazioni sopra.${NC}"
    exit 0
else
    echo ""
    echo -e "${GREEN}Tutti i check superati — lo stack è pronto per l'accesso esterno.${NC}"
    exit 0
fi
