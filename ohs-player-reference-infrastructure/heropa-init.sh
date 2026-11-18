#!/usr/bin/env bash
#
# heropa-init.sh points the stack at this VM's public address and starts it
# over HTTPS, so Heropa's Web component can embed it.
#
# Each Heropa environment gets its own public IP, and that address is baked
# into the Keycloak realm and the Web Portal bundle. So this runs once per
# student environment, after launch and before anything else.
#
#   ./heropa-init.sh [--reset] [dev.sh up flags]
#
# It does four things.
#
#   1. Reads the public IP from the AWS instance metadata service.
#   2. Writes the HTTPS values into .env (PUBLIC_HOST, KEYCLOAK_PUBLIC_URL,
#      OHS_PLAYER_APP_HOST, VITE_FHIR_BASE_URL, BIND_ADDR, COMPOSE_FILE and
#      FRAME_ANCESTORS).
#   3. Obtains a Let's Encrypt certificate for PUBLIC_HOST with certbot.
#   4. Runs ./dev.sh up --proxy with any flags given, for example --pipes.
#
# Settings come from the environment, and each one falls back to .env.
#
#   FRAME_ANCESTORS  the Heropa portal origin, for example
#                    https://yourcompany.heropa.com (required)
#   PUBLIC_IP        skips the metadata lookup
#   PUBLIC_HOST      overrides the default <a-b-c-d>.sslip.io name
#   CERTBOT_EMAIL    Let's Encrypt account address, optional
#
# The Heropa VM needs a permanent public IP and inbound TCP 80, 443, 8443 and
# 9443 from anywhere. Let's Encrypt validates over port 80 from addresses it
# does not publish, so that rule cannot be narrowed. 8443 and 9443 carry
# Superset and the pipeline controller once the analytics are running.
#
# Changing the address of a stack that already ran needs a fresh realm, because
# Keycloak only imports it into an empty database. Pass --reset to wipe the
# volumes in that case. It deletes all FHIR and Keycloak data.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
OVERLAY="docker-compose.yaml:docker-compose.heropa.yml"
NGINX_CONTAINER="ohs-nginx"

info()  { printf '\033[0;32m[INFO]\033[0m  %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*" >&2; }
error() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

# --- arguments --------------------------------------------------------------

RESET=0
UP_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --reset) RESET=1 ;;
        --proxy) ;;                 # always added below
        *)       UP_ARGS+=("$arg") ;;
    esac
done

# --- .env helpers -----------------------------------------------------------

# Prints the value of KEY in .env, without surrounding quotes.
env_get() {
    [[ -f "$ENV_FILE" ]] || return 0
    sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1 | sed -e 's/^"//' -e 's/"$//'
}

# Sets KEY to VALUE in .env, replacing an existing line or appending one.
# awk receives the value through the environment, so no character in it
# needs escaping. The value is written in double quotes because dev.sh loads
# .env with bash, and FRAME_ANCESTORS may hold several origins separated by
# spaces.
env_set() {
    local tmp
    [[ "$2" != *[\"\$\`\\]* ]] || error "Refusing to write $1 with a quote, dollar, backtick or backslash in it."
    tmp="$(mktemp "${TMPDIR:-/tmp}/ohs-heropa-env.XXXXXX")"
    KEY="$1" VALUE="$2" awk '
        BEGIN { key = ENVIRON["KEY"]; line = key "=\"" ENVIRON["VALUE"] "\"" }
        index($0, key "=") == 1 { if (!done) print line; done = 1; next }
        { print }
        END { if (!done) print line }
    ' "$ENV_FILE" > "$tmp"
    cat "$tmp" > "$ENV_FILE"
    rm -f "$tmp"
}

# --- 1. preflight -----------------------------------------------------------

command -v docker  >/dev/null 2>&1 || error "docker is not installed. Run provision-heropa.sh first."
command -v certbot >/dev/null 2>&1 || error "certbot is not installed. Run provision-heropa.sh first."
command -v curl    >/dev/null 2>&1 || error "curl is not installed."
docker info >/dev/null 2>&1 \
    || error "Cannot talk to Docker. Log out and back in, or run newgrp docker, then retry."

if [[ ! -f "$ENV_FILE" ]]; then
    info "No .env found, so creating it from .env.example"
    cp "$SCRIPT_DIR/.env.example" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
fi

FRAME_ANCESTORS="${FRAME_ANCESTORS:-$(env_get FRAME_ANCESTORS)}"
[[ -n "$FRAME_ANCESTORS" ]] \
    || error "Set FRAME_ANCESTORS to the Heropa portal origin, for example FRAME_ANCESTORS=https://yourcompany.heropa.com $0"

CERTBOT_EMAIL="${CERTBOT_EMAIL:-$(env_get CERTBOT_EMAIL)}"

# --- 2. public address ------------------------------------------------------

# IMDSv2 first, which needs a session token, then IMDSv1 for older instances.
lookup_public_ip() {
    local base="http://169.254.169.254/latest" token
    token="$(curl -fsS -m 3 -X PUT "$base/api/token" \
        -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)"
    if [[ -n "$token" ]]; then
        curl -fsS -m 3 -H "X-aws-ec2-metadata-token: $token" \
            "$base/meta-data/public-ipv4" 2>/dev/null && return 0
    fi
    curl -fsS -m 3 "$base/meta-data/public-ipv4" 2>/dev/null
}

PUBLIC_IP="${PUBLIC_IP:-$(lookup_public_ip || true)}"
[[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || error "Could not read a public IPv4 address. Give the VM a permanent public IP in Heropa, or set PUBLIC_IP."

# sslip.io answers <a-b-c-d>.sslip.io with a.b.c.d, which gives the IP a name
# that Let's Encrypt can issue for without any DNS setup.
PUBLIC_HOST="${PUBLIC_HOST:-${PUBLIC_IP//./-}.sslip.io}"
PUBLIC_URL="https://$PUBLIC_HOST"
info "Public IP is $PUBLIC_IP and the lab will answer at $PUBLIC_URL"

# --- 3. stale realm check ---------------------------------------------------

PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$SCRIPT_DIR")}"
PREVIOUS_URL="$(env_get KEYCLOAK_PUBLIC_URL)"
if [[ "$PREVIOUS_URL" != "$PUBLIC_URL" ]] \
    && docker volume inspect "${PROJECT}_postgres_data" >/dev/null 2>&1; then
    if (( RESET )); then
        info "The address changed from ${PREVIOUS_URL:-unset}, so the volumes are being reset"
        "$SCRIPT_DIR/dev.sh" reset
    else
        error "The address changed from ${PREVIOUS_URL:-unset} to $PUBLIC_URL but Keycloak still holds the old realm. Rerun with --reset, which deletes all FHIR and Keycloak data."
    fi
fi

# --- 4. .env ----------------------------------------------------------------

info "Writing the HTTPS settings into .env"
env_set PUBLIC_HOST         "$PUBLIC_HOST"
env_set KEYCLOAK_PUBLIC_URL "$PUBLIC_URL"
env_set OHS_PLAYER_APP_HOST "$PUBLIC_HOST"
env_set VITE_FHIR_BASE_URL  "$PUBLIC_URL/fhir"
env_set BIND_ADDR           "127.0.0.1"
env_set COMPOSE_FILE        "$OVERLAY"
env_set FRAME_ANCESTORS     "$FRAME_ANCESTORS"

# --- 5. certificate ---------------------------------------------------------

if sudo test -s "/etc/letsencrypt/live/$PUBLIC_HOST/fullchain.pem"; then
    info "A certificate for $PUBLIC_HOST is already in place"
else
    info "Requesting a certificate for $PUBLIC_HOST"
    email_args=(--register-unsafely-without-email)
    [[ -n "$CERTBOT_EMAIL" ]] && email_args=(--email "$CERTBOT_EMAIL")

    # certbot listens on port 80 itself. The hooks free the port from nginx
    # and give it back, and certbot saves them for every later renewal.
    sudo certbot certonly --standalone --non-interactive --agree-tos \
        "${email_args[@]}" \
        --cert-name "$PUBLIC_HOST" -d "$PUBLIC_HOST" \
        --pre-hook  "docker stop $NGINX_CONTAINER >/dev/null 2>&1 || true" \
        --post-hook "docker start $NGINX_CONTAINER >/dev/null 2>&1 || true" \
        || error "certbot failed. Check that the Heropa network rules allow inbound TCP 80 from 0.0.0.0/0 and that $PUBLIC_HOST resolves to $PUBLIC_IP."
fi

# --- 6. start ---------------------------------------------------------------

info "Starting the stack behind the HTTPS front"
"$SCRIPT_DIR/dev.sh" up --proxy ${UP_ARGS[@]+"${UP_ARGS[@]}"}

cat <<EOF

The lab is served at $PUBLIC_URL

  Web Portal, gateway and Keycloak   $PUBLIC_URL
  Superset                           $PUBLIC_URL:8443
  Pipeline control panel             $PUBLIC_URL:9443

Superset and the pipeline control panel answer once ./dev.sh up --pipes has run.
Port 80 only redirects.
EOF
