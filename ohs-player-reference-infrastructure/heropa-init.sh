#!/usr/bin/env bash
#
# heropa-init.sh points the stack at this VM's lab address and starts it over
# HTTPS, with each app under its own path on that one address.
#
#   /web         Web Portal, which nginx redirects to /
#   /keycloak/   Keycloak, with the admin console at /keycloak/admin/
#   /gateway/    FHIR gateway
#   /superset/   Superset, once ./dev.sh up --pipes has run
#   /pipeline/   pipeline control panel, once ./dev.sh up --pipes has run
#
# The lab address is baked into the Keycloak realm and the Web Portal bundle,
# so this runs once per student environment, after launch and before anything
# else.
#
#   ./heropa-init.sh [--reset] [dev.sh up flags]
#
# It does five things.
#
#   1. Works out the lab address. It reads the VM's public IP from the AWS
#      instance metadata service and always uses https://<a-b-c-d>.sslip.io,
#      a name that sslip.io's public DNS answers with that IP. Every app,
#      Keycloak's issuer and the certificate use that one name.
#   2. Writes the lab settings into .env (LAB_URL, KEYCLOAK_PUBLIC_URL,
#      OHS_PLAYER_APP_HOST, VITE_FHIR_BASE_URL, BIND_ADDR, COMPOSE_FILE and
#      FRAME_ANCESTORS).
#   3. Gets a Let's Encrypt certificate for that name through the certbot
#      image, for nginx to serve on 443.
#   4. Builds a trust store so the gateway accepts that certificate when it
#      reaches Keycloak inside Docker.
#   5. Runs ./dev.sh up --proxy with any flags given, for example --pipes.
#
# Settings come from the environment, then .env, then .env.example.
#
#   PUBLIC_IP      skips the metadata lookup, for testing off Heropa
#   LAB_CERT       self-signed, for testing where Let's Encrypt cannot reach
#                  the machine. The default is letsencrypt.
#
# LAB_URL is written by this script and never read from anywhere. A value
# already in .env, such as the Heropa portal address, is replaced.
#   CERTBOT_EMAIL  Let's Encrypt account address, optional
#
# For a Let's Encrypt certificate the Heropa VM needs a permanent public IP
# and inbound TCP 80 and 443 from 0.0.0.0/0. Let's Encrypt checks over port 80
# from addresses it does not publish, so that rule cannot be narrowed.
# Outbound traffic must stay open to pull images and reach Let's Encrypt.
#
# Changing the address of a stack that already ran needs a fresh realm, because
# Keycloak only imports it into an empty database. Pass --reset to wipe the
# volumes in that case. It deletes all FHIR and Keycloak data.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
EXAMPLE_FILE="$SCRIPT_DIR/.env.example"
OVERLAY="docker-compose.yaml:docker-compose.heropa.yml"
NGINX_CONTAINER="ohs-nginx"
CERTBOT_IMAGE="certbot/certbot:v3.0.1"
CERT_DIR="$SCRIPT_DIR/nginx/heropa/certs"
# Kept apart from CERT_DIR so ./dev.sh clean leaves the Let's Encrypt account
# and certificate alone. Let's Encrypt issues the same name only five times a
# week, so a test cycle of clean and init must not ask for a new one each time.
LE_DIR="$SCRIPT_DIR/nginx/heropa/letsencrypt"

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

# Prints the value of KEY in .env, or in the file given as the second
# argument, without surrounding quotes.
env_get() {
    local file="${2:-$ENV_FILE}"
    [[ -f "$file" ]] || return 0
    sed -n "s/^$1=//p" "$file" | tail -n 1 | sed -e 's/^"//' -e 's/"$//'
}

# Reads KEY from the environment, then .env, then .env.example. A .env made by
# an earlier run keeps an empty value even after .env.example is edited, which
# is why .env.example is the last fallback.
setting() {
    local value="${!1:-}"
    [[ -n "$value" ]] || value="$(env_get "$1")"
    [[ -n "$value" ]] || value="$(env_get "$1" "$EXAMPLE_FILE")"
    printf '%s' "$value"
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
command -v curl    >/dev/null 2>&1 || error "curl is not installed."
command -v openssl >/dev/null 2>&1 || error "openssl is not installed. Run sudo apt-get install -y openssl"
docker info >/dev/null 2>&1 \
    || error "Cannot talk to Docker. Log out and back in, or run newgrp docker, then retry."

if [[ ! -f "$ENV_FILE" ]]; then
    info "No .env found, so creating it from .env.example"
    cp "$EXAMPLE_FILE" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
fi

FRAME_ANCESTORS="https://ohs.heropa.com"
[[ -n "$FRAME_ANCESTORS" ]] \
    || error "Set FRAME_ANCESTORS to the Heropa portal origin, for example FRAME_ANCESTORS=https://yourcompany.heropa.com $0"

CERTBOT_EMAIL="$(setting CERTBOT_EMAIL)"

# --- 2. lab address ---------------------------------------------------------

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

OLD_LAB_URL="$(env_get LAB_URL)"
PUBLIC_IP="${PUBLIC_IP:-$(lookup_public_ip || true)}"
[[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || error "Could not read a public IPv4 address. Give the VM a permanent public IP in Heropa, or set PUBLIC_IP."
info "Public IP is $PUBLIC_IP"
LAB_HOST="${PUBLIC_IP//./-}.sslip.io"
LAB_URL="https://$LAB_HOST"
if [[ -n "$OLD_LAB_URL" && "$OLD_LAB_URL" != "$LAB_URL" ]]; then
    warn "Replacing LAB_URL=$OLD_LAB_URL in .env with $LAB_URL"
fi

LAB_CERT="$(setting LAB_CERT)"
LAB_CERT="${LAB_CERT:-letsencrypt}"
[[ "$LAB_CERT" == letsencrypt || "$LAB_CERT" == self-signed ]] \
    || error "LAB_CERT must be letsencrypt or self-signed, not $LAB_CERT"

info "The lab will answer at $LAB_URL with a $LAB_CERT certificate"

# --- 3. stale realm check ---------------------------------------------------

PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$SCRIPT_DIR")}"
KEYCLOAK_URL="$LAB_URL/keycloak"
PREVIOUS_URL="$(env_get KEYCLOAK_PUBLIC_URL)"
if [[ "$PREVIOUS_URL" != "$KEYCLOAK_URL" ]] \
    && docker volume inspect "${PROJECT}_postgres_data" >/dev/null 2>&1; then
    if (( RESET )); then
        info "The address changed from ${PREVIOUS_URL:-unset}, so the volumes are being reset"
        "$SCRIPT_DIR/dev.sh" reset
    else
        error "The address changed from ${PREVIOUS_URL:-unset} to $KEYCLOAK_URL but Keycloak still holds the old realm. Rerun with --reset, which deletes all FHIR and Keycloak data."
    fi
fi

# --- 4. .env ----------------------------------------------------------------

info "Writing the lab settings into .env"
env_set LAB_URL             "$LAB_URL"
env_set KEYCLOAK_PUBLIC_URL "$KEYCLOAK_URL"
env_set OHS_PLAYER_APP_HOST "$LAB_HOST"
env_set VITE_FHIR_BASE_URL  "$LAB_URL/gateway/fhir"
env_set BIND_ADDR           "127.0.0.1"
env_set COMPOSE_FILE        "$OVERLAY"
env_set FRAME_ANCESTORS     "$FRAME_ANCESTORS"

# --- 5. certificate ---------------------------------------------------------

mkdir -p "$CERT_DIR"

# True when lab.crt names LAB_HOST and stays valid for at least DAYS more.
cert_fits() {
    local days="$1"
    openssl x509 -in "$CERT_DIR/lab.crt" -noout -checkhost "$LAB_HOST" 2>/dev/null | grep -q 'does match' \
        && openssl x509 -in "$CERT_DIR/lab.crt" -noout -checkend $(( days * 86400 )) >/dev/null 2>&1 \
        && [[ -s "$CERT_DIR/lab.key" ]]
}

# True when lab.crt signed itself, which is how a leftover test certificate
# is told apart from a Let's Encrypt one.
cert_self_signed() {
    [[ "$(openssl x509 -in "$CERT_DIR/lab.crt" -noout -subject 2>/dev/null | sed 's/^subject=//')" \
        == "$(openssl x509 -in "$CERT_DIR/lab.crt" -noout -issuer 2>/dev/null | sed 's/^issuer=//')" ]]
}

if [[ "$LAB_CERT" == letsencrypt ]]; then
    if cert_fits 30 && ! cert_self_signed; then
        info "The Let's Encrypt certificate for $LAB_HOST is already in place"
    else
        info "Requesting a Let's Encrypt certificate for $LAB_HOST"
        email_args=(--register-unsafely-without-email)
        [[ -n "$CERTBOT_EMAIL" ]] && email_args=(--email "$CERTBOT_EMAIL")

        # certbot answers the check on port 80 itself, so nginx gives the port
        # up for the minute this takes. ./dev.sh up starts it again below.
        docker stop "$NGINX_CONTAINER" >/dev/null 2>&1 || true
        mkdir -p "$LE_DIR"
        docker run --rm -p 80:80 -v "$LE_DIR:/etc/letsencrypt" "$CERTBOT_IMAGE" \
            certonly --standalone --non-interactive --agree-tos --keep-until-expiring \
            "${email_args[@]}" --cert-name "$LAB_HOST" -d "$LAB_HOST" \
            || error "certbot failed. Check that the Heropa network rules allow inbound TCP 80 from 0.0.0.0/0 and that $LAB_HOST resolves to this VM's public IP."

        # certbot writes as root and keeps symlinks under live/. Copy plain
        # files that nginx can read and this user can replace later.
        docker run --rm -v "$LE_DIR:/etc/letsencrypt" -v "$CERT_DIR:/out" \
            --entrypoint sh "$CERTBOT_IMAGE" -c '
                cp -L "/etc/letsencrypt/live/$1/fullchain.pem" /out/lab.crt &&
                cp -L "/etc/letsencrypt/live/$1/privkey.pem" /out/lab.key &&
                chown "$2" /out/lab.crt /out/lab.key &&
                chmod 644 /out/lab.crt /out/lab.key' sh "$LAB_HOST" "$(id -u):$(id -g)" \
            || error "Could not copy the certificate out of $LE_DIR."
    fi
elif ! cert_fits 1; then
    info "Making a self-signed certificate for $LAB_HOST"
    rm -f "$CERT_DIR/lab.crt" "$CERT_DIR/lab.key"
    openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
        -subj "/CN=$LAB_HOST" -addext "subjectAltName=DNS:$LAB_HOST" \
        -keyout "$CERT_DIR/lab.key" -out "$CERT_DIR/lab.crt" 2>/dev/null
    chmod 644 "$CERT_DIR/lab.key"   # read by nginx inside its container
fi

# --- 6. gateway trust store -------------------------------------------------

# nginx answers the lab host name on 443 inside Docker as well, through the
# network alias in docker-compose.heropa.yml, so the gateway reaches Keycloak
# without leaving the VM. A Let's Encrypt certificate is trusted anyway, and a
# self-signed one is trusted through this copy of the Java trust store. The
# gateway image is built on eclipse-temurin 21, so its keytool and default
# trust store match the JVM that loads the result.
if [[ ! -s "$CERT_DIR/truststore.p12" || "$CERT_DIR/lab.crt" -nt "$CERT_DIR/truststore.p12" ]]; then
    info "Building the gateway trust store"
    rm -f "$CERT_DIR/truststore.p12"
    docker run --rm --user "$(id -u):$(id -g)" -v "$CERT_DIR:/certs" \
        --entrypoint sh eclipse-temurin:21-jre -c '
            cp "$JAVA_HOME/lib/security/cacerts" /certs/truststore.p12 &&
            chmod 644 /certs/truststore.p12 &&
            keytool -importcert -noprompt -alias ohs-lab -file /certs/lab.crt \
                -keystore /certs/truststore.p12 -storepass changeit >/dev/null' \
        || error "Could not build the gateway trust store."
    # Containers that already loaded the old trust store keep it until they restart.
    docker restart ohs-fhir-gateway >/dev/null 2>&1 || true
fi

# --- 7. start ---------------------------------------------------------------

info "Starting the stack behind the nginx front"
"$SCRIPT_DIR/dev.sh" up --proxy ${UP_ARGS[@]+"${UP_ARGS[@]}"}

# The check goes out to the public address and back, the same way a student's
# browser arrives. A self-signed certificate is checked against itself.
curl_args=()
[[ "$LAB_CERT" == self-signed ]] && curl_args=(--cacert "$CERT_DIR/lab.crt")
if curl -fsS -m 10 -o /dev/null ${curl_args[@]+"${curl_args[@]}"} \
    "$KEYCLOAK_URL/realms/ohs-player/.well-known/openid-configuration"; then
    info "$LAB_URL answers from outside the VM"
else
    warn "$LAB_URL did not answer. Check that $LAB_HOST resolves to this VM's public IP and that inbound TCP 443 is open."
fi

cat <<EOF

The lab is served at $LAB_URL

  Web Portal               $LAB_URL/web
  Keycloak admin console   $LAB_URL/keycloak/admin/
  FHIR gateway             $LAB_URL/gateway/fhir/metadata
  Superset                 $LAB_URL/superset/
  Pipeline control panel   $LAB_URL/pipeline/

Superset and the pipeline control panel answer once ./dev.sh up --pipes has run.
Open these in a browser tab on your own computer.
EOF
