#!/usr/bin/env bash
#
# heropa-init.sh points the stack at this VM's lab address and starts it, so
# Heropa's Iframe interfaces can show each app as a tab.
#
# Cloudflare holds the HTTPS certificate for the lab address and forwards plain
# HTTP to port 80 on this VM. nginx then serves each app under its own path.
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
# It does three things.
#
#   1. Writes the lab settings into .env (KEYCLOAK_PUBLIC_URL,
#      OHS_PLAYER_APP_HOST, VITE_FHIR_BASE_URL, BIND_ADDR, COMPOSE_FILE,
#      LAB_URL and FRAME_ANCESTORS).
#   2. Checks that the lab address reaches this VM through Cloudflare.
#   3. Runs ./dev.sh up --proxy with any flags given, for example --pipes.
#
# Settings come from the environment, then .env, then .env.example.
#
#   LAB_URL          the HTTPS address Cloudflare serves for this VM, for
#                    example https://lab-01.example.org (required)
#   FRAME_ANCESTORS  the Heropa portal origin, for example
#                    https://yourcompany.heropa.com (required)
#
# The Heropa VM needs inbound TCP 80 from Cloudflare and outbound HTTPS. The
# gateway checks sign-in tokens against Keycloak at LAB_URL/keycloak, so it reaches
# Keycloak the same way a browser does, out through Cloudflare and back.
#
# Changing the address of a stack that already ran needs a fresh realm, because
# Keycloak only imports it into an empty database. Pass --reset to wipe the
# volumes in that case. It deletes all FHIR and Keycloak data.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
EXAMPLE_FILE="$SCRIPT_DIR/.env.example"
OVERLAY="docker-compose.yaml:docker-compose.heropa.yml"

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

command -v docker >/dev/null 2>&1 || error "docker is not installed. Run provision-heropa.sh first."
command -v curl   >/dev/null 2>&1 || error "curl is not installed."
docker info >/dev/null 2>&1 \
    || error "Cannot talk to Docker. Log out and back in, or run newgrp docker, then retry."

if [[ ! -f "$ENV_FILE" ]]; then
    info "No .env found, so creating it from .env.example"
    cp "$EXAMPLE_FILE" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
fi

LAB_URL="$(setting LAB_URL)"
LAB_URL="${LAB_URL%/}"
[[ -n "$LAB_URL" ]] \
    || error "Set LAB_URL to the HTTPS address Cloudflare serves for this VM, for example LAB_URL=https://lab-01.example.org $0"
[[ "$LAB_URL" =~ ^https://[A-Za-z0-9.-]+$ ]] \
    || error "LAB_URL must be https:// followed by a host name and nothing else, not $LAB_URL"
LAB_HOST="${LAB_URL#https://}"

FRAME_ANCESTORS="https://ohs.heropa.com"
[[ -n "$FRAME_ANCESTORS" ]] \
    || error "Set FRAME_ANCESTORS to the Heropa portal origin, for example FRAME_ANCESTORS=https://yourcompany.heropa.com $0"

info "The lab will answer at $LAB_URL"

# --- 2. stale realm check ---------------------------------------------------

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

# --- 3. .env ----------------------------------------------------------------

info "Writing the lab settings into .env"
env_set LAB_URL             "$LAB_URL"
env_set KEYCLOAK_PUBLIC_URL "$KEYCLOAK_URL"
env_set OHS_PLAYER_APP_HOST "$LAB_HOST"
env_set VITE_FHIR_BASE_URL  "$LAB_URL/gateway/fhir"
env_set BIND_ADDR           "127.0.0.1"
env_set COMPOSE_FILE        "$OVERLAY"
env_set FRAME_ANCESTORS     "$FRAME_ANCESTORS"

# --- 4. start ---------------------------------------------------------------

info "Starting the stack behind the nginx front"
"$SCRIPT_DIR/dev.sh" up --proxy ${UP_ARGS[@]+"${UP_ARGS[@]}"}

# The gateway reached Keycloak at LAB_URL to start at all, so a failure here
# usually means Cloudflare is not yet sending the name to this VM.
if curl -fsS -m 10 -o /dev/null "$KEYCLOAK_URL/realms/ohs-player/.well-known/openid-configuration"; then
    info "$LAB_URL reaches this VM through Cloudflare"
else
    warn "$LAB_URL did not answer. Check that Cloudflare points $LAB_HOST at this VM and that inbound TCP 80 is open."
fi

cat <<EOF

The lab is served at $LAB_URL. Give each Heropa Iframe interface one of
these paths.

  Web Portal               /web
  Keycloak admin console   /keycloak/admin/
  FHIR gateway             /gateway/fhir/metadata
  Superset                 /superset/
  Pipeline control panel   /pipeline/

Superset and the pipeline control panel answer once ./dev.sh up --pipes has run.
EOF
