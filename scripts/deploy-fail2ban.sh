#!/bin/bash
# =============================================================================
# deploy-fail2ban.sh — Installa le config fail2ban per il MediaServer stack
# =============================================================================
#
# USO:
#   bash scripts/deploy-fail2ban.sh
#
# COSA FA:
#   1. Legge CONFIG_DIR da .env nella root del progetto
#   2. Sostituisce __CONFIG_DIR__ nei template con il path assoluto reale
#   3. Valida i config con fail2ban-client -t (su file temporanei)
#   4. Installa i file validati in /etc/fail2ban/ con sudo
#   5. Ricarica fail2ban e mostra lo status
#
# PREREQUISITI:
#   - fail2ban installato e attivo (systemctl status fail2ban)
#   - sudo disponibile per l'utente corrente
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Colori e helper di output
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERRORE]${NC} $*" >&2; }
die()   { error "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Path del progetto e template
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

TEMPLATE_JAIL="${PROJECT_ROOT}/fail2ban/jail.d/mediaserver.conf"
TEMPLATE_CADDY="${PROJECT_ROOT}/fail2ban/filter.d/caddy.conf"
TEMPLATE_JELLYFIN="${PROJECT_ROOT}/fail2ban/filter.d/jellyfin.conf"

# Directory temporanea per i file con placeholder sostituiti
TMPDIR_FAIL2BAN="$(mktemp -d)"

# Cleanup dei file temporanei
cleanup() {
    if [[ -d "${TMPDIR_FAIL2BAN}" ]]; then
        rm -rf "${TMPDIR_FAIL2BAN}"
    fi
}

# Flag: true dopo che i file sono stati installati in /etc/fail2ban
# Se lo script esce inaspettatamente DOPO l'installazione, ripristina i backup
FILES_INSTALLED=false

on_exit() {
    if [[ "${FILES_INSTALLED}" == "true" ]]; then
        # Script uscito inaspettatamente dopo l'installazione temporanea:
        # ripristina i backup per non lasciare /etc/fail2ban in stato inconsistente
        restore_backups 2>/dev/null || true
    fi
    cleanup
}
trap on_exit EXIT

# ---------------------------------------------------------------------------
# 1. Controllo prerequisiti
# ---------------------------------------------------------------------------
info "Controllo prerequisiti..."

if ! command -v fail2ban-client &>/dev/null; then
    die "fail2ban-client non trovato. Installa fail2ban: sudo pacman -S fail2ban"
fi

if ! systemctl is-active --quiet fail2ban; then
    die "Il servizio fail2ban non è attivo. Avvialo con: sudo systemctl start fail2ban"
fi

ok "fail2ban installato e attivo"

# ---------------------------------------------------------------------------
# 2. Lettura .env e risoluzione CONFIG_DIR
# ---------------------------------------------------------------------------
info "Lettura configurazione da ${ENV_FILE}..."

if [[ ! -f "${ENV_FILE}" ]]; then
    die ".env non trovato in ${PROJECT_ROOT}. Copia .env.example in .env e compila i valori."
fi

# Estrai CONFIG_DIR ignorando righe commentate, espandi variabili semplici
CONFIG_DIR_RAW="$(grep -E '^CONFIG_DIR=' "${ENV_FILE}" | tail -1 | cut -d'=' -f2-)"

if [[ -z "${CONFIG_DIR_RAW}" ]]; then
    die "CONFIG_DIR non trovato in .env"
fi

# Risolvi path relativo rispetto alla root del progetto
if [[ "${CONFIG_DIR_RAW}" == ./* || "${CONFIG_DIR_RAW}" == . ]]; then
    CONFIG_DIR_ABS="$(cd "${PROJECT_ROOT}" && realpath -m "${CONFIG_DIR_RAW}")"
else
    CONFIG_DIR_ABS="${CONFIG_DIR_RAW}"
fi

ok "CONFIG_DIR risolto: ${CONFIG_DIR_ABS}"

# ---------------------------------------------------------------------------
# 3. Controllo esistenza template
# ---------------------------------------------------------------------------
info "Controllo file template..."

for f in "${TEMPLATE_JAIL}" "${TEMPLATE_CADDY}" "${TEMPLATE_JELLYFIN}"; do
    if [[ ! -f "${f}" ]]; then
        die "Template non trovato: ${f}"
    fi
done

ok "Tutti i template trovati"

# ---------------------------------------------------------------------------
# 4. Sostituzione __CONFIG_DIR__ nei file temporanei
# ---------------------------------------------------------------------------
info "Sostituzione __CONFIG_DIR__ → ${CONFIG_DIR_ABS}..."

mkdir -p "${TMPDIR_FAIL2BAN}/jail.d" "${TMPDIR_FAIL2BAN}/filter.d"

TMP_JAIL="${TMPDIR_FAIL2BAN}/jail.d/mediaserver.conf"
TMP_CADDY="${TMPDIR_FAIL2BAN}/filter.d/caddy.conf"
TMP_JELLYFIN="${TMPDIR_FAIL2BAN}/filter.d/jellyfin.conf"

# Usa un separatore alternativo per sed per evitare conflitti con i / nei path
sed "s|__CONFIG_DIR__|${CONFIG_DIR_ABS}|g" "${TEMPLATE_JAIL}"     > "${TMP_JAIL}"
sed "s|__CONFIG_DIR__|${CONFIG_DIR_ABS}|g" "${TEMPLATE_CADDY}"    > "${TMP_CADDY}"
sed "s|__CONFIG_DIR__|${CONFIG_DIR_ABS}|g" "${TEMPLATE_JELLYFIN}" > "${TMP_JELLYFIN}"

ok "Sostituzione completata nei file temporanei"

# ---------------------------------------------------------------------------
# 5. Validazione con fail2ban-client -t
# ---------------------------------------------------------------------------
info "Validazione configurazione con fail2ban-client -t..."

# fail2ban-client -t legge dall'installazione di sistema, non dai file temporanei.
# Installiamo prima in un path temporaneo sovrascrivibile, poi validiamo.
# Strategia: copiamo i file temporanei in /tmp con nomi univoci e usiamo
# fail2ban-regex per validare i filtri, e controlliamo la sintassi del jail
# con python/fail2ban-client sulle config temporanee.

# Validazione sintattica basilare: verifica che i file abbiano sezioni valide
for tmp_file in "${TMP_JAIL}" "${TMP_CADDY}" "${TMP_JELLYFIN}"; do
    if ! grep -qE '^\[.+\]' "${tmp_file}"; then
        die "Sintassi non valida (nessuna sezione trovata) in: ${tmp_file}"
    fi
    # Verifica che non ci siano placeholder rimasti
    if grep -q '__CONFIG_DIR__' "${tmp_file}"; then
        die "Placeholder __CONFIG_DIR__ non sostituito in: ${tmp_file}"
    fi
done

ok "Sintassi dei template verificata"

# Validazione completa: installa temporaneamente e testa con fail2ban-client -t
# Prima salva eventuali file esistenti, poi ripristina dopo il test
BACKUP_JAIL=""
BACKUP_CADDY=""
BACKUP_JELLYFIN=""

if [[ -f /etc/fail2ban/jail.d/mediaserver.conf ]]; then
    BACKUP_JAIL="$(mktemp)"
    sudo cp /etc/fail2ban/jail.d/mediaserver.conf "${BACKUP_JAIL}"
fi
if [[ -f /etc/fail2ban/filter.d/caddy.conf ]]; then
    BACKUP_CADDY="$(mktemp)"
    sudo cp /etc/fail2ban/filter.d/caddy.conf "${BACKUP_CADDY}"
fi
if [[ -f /etc/fail2ban/filter.d/jellyfin.conf ]]; then
    BACKUP_JELLYFIN="$(mktemp)"
    sudo cp /etc/fail2ban/filter.d/jellyfin.conf "${BACKUP_JELLYFIN}"
fi

# Funzione di ripristino backup in caso di errore nella fase di test
restore_backups() {
    warn "Ripristino backup precedenti dopo errore di validazione..."
    if [[ -n "${BACKUP_JAIL}" && -f "${BACKUP_JAIL}" ]]; then
        sudo install -m 0644 "${BACKUP_JAIL}" /etc/fail2ban/jail.d/mediaserver.conf
        rm -f "${BACKUP_JAIL}"
    else
        sudo rm -f /etc/fail2ban/jail.d/mediaserver.conf
    fi
    if [[ -n "${BACKUP_CADDY}" && -f "${BACKUP_CADDY}" ]]; then
        sudo install -m 0644 "${BACKUP_CADDY}" /etc/fail2ban/filter.d/caddy.conf
        rm -f "${BACKUP_CADDY}"
    else
        sudo rm -f /etc/fail2ban/filter.d/caddy.conf
    fi
    if [[ -n "${BACKUP_JELLYFIN}" && -f "${BACKUP_JELLYFIN}" ]]; then
        sudo install -m 0644 "${BACKUP_JELLYFIN}" /etc/fail2ban/filter.d/jellyfin.conf
        rm -f "${BACKUP_JELLYFIN}"
    else
        sudo rm -f /etc/fail2ban/filter.d/jellyfin.conf
    fi
    cleanup
}

# Installa temporaneamente per la validazione
sudo install -m 0644 "${TMP_JAIL}"     /etc/fail2ban/jail.d/mediaserver.conf
sudo install -m 0644 "${TMP_CADDY}"    /etc/fail2ban/filter.d/caddy.conf
sudo install -m 0644 "${TMP_JELLYFIN}" /etc/fail2ban/filter.d/jellyfin.conf

# Da questo punto il trap on_exit chiamerebbe restore_backups in caso di exit inatteso
FILES_INSTALLED=true

info "Esecuzione fail2ban-client -t per validazione completa..."
if ! sudo fail2ban-client -t 2>&1; then
    restore_backups
    FILES_INSTALLED=false
    die "Validazione fail2ban FALLITA. Configurazione non installata."
fi

ok "Validazione fail2ban superata"

# Validazione passata: disabilita il rollback automatico e pulisci i backup
FILES_INSTALLED=false
[[ -n "${BACKUP_JAIL}"     && -f "${BACKUP_JAIL}"     ]] && rm -f "${BACKUP_JAIL}"
[[ -n "${BACKUP_CADDY}"    && -f "${BACKUP_CADDY}"    ]] && rm -f "${BACKUP_CADDY}"
[[ -n "${BACKUP_JELLYFIN}" && -f "${BACKUP_JELLYFIN}" ]] && rm -f "${BACKUP_JELLYFIN}"

# ---------------------------------------------------------------------------
# 6. I file sono già installati (dalla fase di validazione) — solo conferma
# ---------------------------------------------------------------------------
info "File installati correttamente:"
echo "  /etc/fail2ban/jail.d/mediaserver.conf"
echo "  /etc/fail2ban/filter.d/caddy.conf"
echo "  /etc/fail2ban/filter.d/jellyfin.conf"

# ---------------------------------------------------------------------------
# 7. Ricarica fail2ban
# ---------------------------------------------------------------------------
info "Ricarica fail2ban..."
sudo fail2ban-client reload

ok "fail2ban ricaricato con successo"

# ---------------------------------------------------------------------------
# 8. Status finale
# ---------------------------------------------------------------------------
echo ""
info "Status fail2ban:"
sudo fail2ban-client status

echo ""
ok "Deploy completato."
echo ""
echo "  Jail 'caddy-auth' abilitata e attiva."
echo "  Jail 'jellyfin-auth' DISABILITATA di default."
echo "  Abilitala in /etc/fail2ban/jail.d/mediaserver.conf SOLO dopo aver"
echo "  configurato 'Known Proxies' in Jellyfin (Dashboard → Networking)."
