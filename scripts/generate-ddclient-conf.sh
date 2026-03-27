#!/bin/bash

# Genera ddclient.conf per il container ddclient.
# Uso: scripts/generate-ddclient-conf.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

# --- Leggi CONFIG_DIR da .env ---
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Errore: file .env non trovato in $SCRIPT_DIR/.." >&2
  echo "Copia .env.example in .env e compilalo prima di eseguire questo script." >&2
  exit 1
fi

CONFIG_DIR="$(grep -E '^CONFIG_DIR=' "$ENV_FILE" | cut -d'=' -f2- | tr -d '"'"'")"

if [[ -z "$CONFIG_DIR" ]]; then
  echo "Errore: CONFIG_DIR non trovato in $ENV_FILE" >&2
  exit 1
fi

# Risolvi in percorso assoluto (può essere relativo alla root del progetto)
PROJECT_ROOT="$SCRIPT_DIR/.."
if [[ "$CONFIG_DIR" != /* ]]; then
  CONFIG_DIR="$(cd "$PROJECT_ROOT" && realpath -m "$CONFIG_DIR")"
fi

OUTPUT_DIR="$CONFIG_DIR/ddclient"
OUTPUT_FILE="$OUTPUT_DIR/ddclient.conf"

echo "=== Generatore configurazione ddclient ==="
echo ""

# --- Scelta provider ---
echo "Seleziona provider DDNS:"
echo "  1) DuckDNS"
echo "  2) Cloudflare"
echo ""

PROVIDER=""
while [[ -z "$PROVIDER" ]]; do
  read -rp "Scelta [1/2]: " choice
  case "$choice" in
    1) PROVIDER="duckdns" ;;
    2) PROVIDER="cloudflare" ;;
    *) echo "Scelta non valida. Inserisci 1 o 2." ;;
  esac
done

echo ""

# --- Raccogli credenziali ---
if [[ "$PROVIDER" == "duckdns" ]]; then
  DUCKDNS_TOKEN=""
  while [[ -z "$DUCKDNS_TOKEN" ]]; do
    read -rp "Token DuckDNS: " DUCKDNS_TOKEN
    [[ -z "$DUCKDNS_TOKEN" ]] && echo "Il token non può essere vuoto."
  done

  DUCKDNS_SUBDOMAIN=""
  while [[ -z "$DUCKDNS_SUBDOMAIN" ]]; do
    read -rp "Sottodominio (solo la parte prima di .duckdns.org): " DUCKDNS_SUBDOMAIN
    [[ -z "$DUCKDNS_SUBDOMAIN" ]] && echo "Il sottodominio non può essere vuoto."
  done

else  # cloudflare
  CF_EMAIL=""
  while [[ -z "$CF_EMAIL" ]]; do
    read -rp "Email Cloudflare: " CF_EMAIL
    [[ -z "$CF_EMAIL" ]] && echo "L'email non può essere vuota."
  done

  CF_API_TOKEN=""
  while [[ -z "$CF_API_TOKEN" ]]; do
    read -rp "API Token Cloudflare: " CF_API_TOKEN
    [[ -z "$CF_API_TOKEN" ]] && echo "L'API token non può essere vuoto."
  done

  CF_ZONE=""
  while [[ -z "$CF_ZONE" ]]; do
    read -rp "Zone (dominio root, es: tuodominio.com): " CF_ZONE
    [[ -z "$CF_ZONE" ]] && echo "La zone non può essere vuota."
  done

  CF_SUBDOMAIN=""
  while [[ -z "$CF_SUBDOMAIN" ]]; do
    read -rp "Subdomain FQDN (es: jellyfin.tuodominio.com): " CF_SUBDOMAIN
    [[ -z "$CF_SUBDOMAIN" ]] && echo "Il subdomain non può essere vuoto."
  done
fi

# --- Conferma sovrascrittura se il file esiste ---
if [[ -f "$OUTPUT_FILE" ]]; then
  echo ""
  echo "Attenzione: il file $OUTPUT_FILE esiste già."
  CONFIRM=""
  while [[ "$CONFIRM" != "s" && "$CONFIRM" != "n" ]]; do
    read -rp "Sovrascrivere? [s/n]: " CONFIRM
  done
  if [[ "$CONFIRM" == "n" ]]; then
    echo "Operazione annullata."
    exit 0
  fi
fi

# --- Crea directory e genera il file ---
if ! mkdir -p "$OUTPUT_DIR"; then
  echo "Errore: impossibile creare la directory $OUTPUT_DIR" >&2
  echo "Verifica che CONFIG_DIR sia scrivibile dall'utente corrente." >&2
  exit 1
fi

if [[ "$PROVIDER" == "duckdns" ]]; then
  cat > "$OUTPUT_FILE" <<EOF
daemon=300
syslog=no
pid=/var/run/ddclient/ddclient.pid
ssl=yes
use=web, web=checkip.dyndns.org/, web-skip='IP Address'
protocol=duckdns
login=token
password=${DUCKDNS_TOKEN}
${DUCKDNS_SUBDOMAIN}.duckdns.org
EOF
else
  # Con API token Cloudflare: login=token (non l'email), password=<api_token>
  cat > "$OUTPUT_FILE" <<EOF
daemon=300
syslog=no
pid=/var/run/ddclient/ddclient.pid
ssl=yes
use=web, web=checkip.dyndns.org/, web-skip='IP Address'
protocol=cloudflare
login=token
password=${CF_API_TOKEN}
zone=${CF_ZONE}
${CF_SUBDOMAIN}
EOF
fi

if ! chmod 600 "$OUTPUT_FILE"; then
  echo "Errore: impossibile impostare i permessi su $OUTPUT_FILE" >&2
  exit 1
fi

echo ""
echo "File generato: $OUTPUT_FILE"
echo ""
echo "Per avviare ddclient:"
echo "  docker compose --profile ddns up -d ddclient"
echo ""
echo "Per verificare i log:"
echo "  docker compose logs -f ddclient"
