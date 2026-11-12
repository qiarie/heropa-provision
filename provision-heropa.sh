#!/usr/bin/env bash
#
# provision-heropa.sh prepares the Ubuntu desktop VM behind the Heropa course
# template for the OHS Player reference infrastructure.
#
# It installs the host tools that dev.sh and the course manual call, then
# Docker Engine with the Compose and buildx plugins. Every step is guarded, so
# a second run changes nothing.
#
# Run it from a terminal on the VM with
#
#   sudo ./provision-heropa.sh
#
# Optional settings come from the environment.
#
#   DOCKER_USERS   users to add to the docker group, comma or space separated
#                  (defaults to the user who ran sudo)
#   SKIP_UPGRADE   set it to skip apt-get upgrade
#
# Nothing here opens a port or touches the firewall. Heropa blocks inbound
# traffic and the stack is reached through localhost from the browser on the VM.

set -euo pipefail
trap 'die "failed at line $LINENO while running $BASH_COMMAND"' ERR

DOCKER_USERS="${DOCKER_USERS:-}"
export DEBIAN_FRONTEND=noninteractive

# Desktop images run unattended-upgrades soon after boot. Wait for its dpkg
# lock instead of failing on it.
APT=(apt-get -o DPkg::Lock::Timeout=600)

CODENAME=""
TARGET_USERS=()
REBOOT_REQUIRED=0

# --- helpers ----------------------------------------------------------------

log()  { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
warn() { printf '[%s] WARNING %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die()  { printf '[%s] ERROR %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; exit 1; }

pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'ok installed'
}

# Install only the packages that are missing, so re-runs stay quiet.
apt_install() {
    local missing=()
    local pkg
    for pkg in "$@"; do
        pkg_installed "$pkg" || missing+=("$pkg")
    done
    if [ ${#missing[@]} -eq 0 ]; then
        return 0
    fi
    log "installing ${missing[*]}"
    "${APT[@]}" install -y "${missing[@]}"
}

# --- 1. preflight -----------------------------------------------------------

resolve_target_users() {
    local candidate

    if [ -n "$DOCKER_USERS" ]; then
        read -r -a TARGET_USERS <<<"${DOCKER_USERS//,/ }"
        return 0
    fi

    candidate="${SUDO_USER:-}"
    if [ -z "$candidate" ] && command -v logname >/dev/null 2>&1; then
        candidate="$(logname 2>/dev/null || true)"
    fi

    if [ -n "$candidate" ] && [ "$candidate" != "root" ]; then
        TARGET_USERS=("$candidate")
    fi
}

preflight() {
    log "=== preflight ==="

    [ "$(id -u)" -eq 0 ] || die "must run as root, so try sudo $0"
    [ -r /etc/os-release ] || die "/etc/os-release is not readable, so this is probably not Ubuntu"

    # shellcheck disable=SC1091
    . /etc/os-release
    CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    [ -n "$CODENAME" ] || die "could not determine the Ubuntu codename"
    log "detected ${PRETTY_NAME:-unknown} (codename $CODENAME, arch $(dpkg --print-architecture))"

    resolve_target_users
    if [ ${#TARGET_USERS[@]} -eq 0 ]; then
        warn "no non-root user resolved, so the docker group step will be skipped"
    else
        log "target user(s) for the docker group are ${TARGET_USERS[*]}"
    fi

    log "updating the package index"
    "${APT[@]}" update

    if [ -n "${SKIP_UPGRADE:-}" ]; then
        log "SKIP_UPGRADE is set, so apt-get upgrade is skipped"
    else
        log "upgrading installed packages"
        "${APT[@]}" upgrade -y
    fi

    [ -f /var/run/reboot-required ] && REBOOT_REQUIRED=1
    return 0
}

# --- 2. base packages -------------------------------------------------------

install_base() {
    log "=== base packages ==="

    # gettext-base provides envsubst, which dev.sh refuses to run without.
    # jq is used throughout the course manual. python3 prints the login
    # details at the end of dev.sh up and ships with the desktop image anyway.
    apt_install ca-certificates curl gnupg git \
        gettext-base jq python3 \
        vim bash-completion
}

# --- 3. docker --------------------------------------------------------------
# https://docs.docker.com/engine/install/ubuntu/#install-using-the-repository

install_docker() {
    log "=== docker ==="

    if ! pkg_installed docker-ce; then
        log "adding the Docker apt repository"
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc

        tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $CODENAME
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

        "${APT[@]}" update
        apt_install docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin
    else
        log "docker-ce is already installed"
    fi

    systemctl enable --now docker

    if [ ${#TARGET_USERS[@]} -eq 0 ]; then
        warn "no target user, so docker group membership is skipped"
        return 0
    fi

    local user
    for user in "${TARGET_USERS[@]}"; do
        if ! id "$user" >/dev/null 2>&1; then
            warn "user '$user' does not exist and was not added to the docker group"
            continue
        fi
        if id -nG "$user" | tr ' ' '\n' | grep -qx docker; then
            log "user '$user' is already in the docker group"
        else
            log "adding user '$user' to the docker group"
            usermod -aG docker "$user"
        fi
    done
}

# --- 4. summary -------------------------------------------------------------

summary() {
    [ -f /var/run/reboot-required ] && REBOOT_REQUIRED=1

    cat <<EOF

============================================================
 Provisioning complete
============================================================

  docker      $(docker --version 2>/dev/null || echo 'not reporting a version')
  compose     $(docker compose version --short 2>/dev/null || echo 'not reporting a version')
  git         $(git --version 2>/dev/null || echo 'not reporting a version')
  envsubst    $({ envsubst --version 2>/dev/null || echo 'not reporting a version'; } | head -1)
  jq          $(jq --version 2>/dev/null || echo 'not reporting a version')
  python3     $(python3 --version 2>/dev/null || echo 'not reporting a version')

Next steps

  1. Log out and back in for docker group membership to take effect,
     or run newgrp docker. Check it with docker run --rm hello-world

  2. Continue with Step 3 of heropa-setup.md and clone the repository.
EOF

    if [ "$REBOOT_REQUIRED" -eq 1 ]; then
        cat <<'EOF'

  A reboot is pending after a kernel or libc update. Reboot before
  saving the template.

       sudo reboot
EOF
    fi

    echo
}

# --- main -------------------------------------------------------------------

main() {
    preflight
    install_base
    install_docker
    summary
}

main "$@"
