#!/usr/bin/env bash
#
# provision-heropa.sh prepares the Ubuntu desktop VM behind the Heropa template
# for the Kotlin FHIR Data Capture and Kotlin FHIR Engine codelabs, run without
# Android Studio.
#
# It installs JDK 21, the Android SDK command-line tools with the packages the
# codelabs compile against, Docker Engine with the Compose plugin for the
# engine codelab's HAPI FHIR server, and both codelab checkouts. Every step is
# guarded, so a second run changes nothing.
#
# The IDE and the Gradle cache warm-up are left to the person building the
# template, because both need the desktop session. See
# .claude/codelabs-on-heropa.md, steps 5 and 7.
#
# Run it from a terminal on the VM with
#
#   sudo ./provision-heropa.sh
#
# Optional settings come from the environment.
#
#   LEARNER_USER     the account learners use, which owns the SDK and the
#                    codelab checkouts (defaults to the user who ran sudo)
#   ENGINE_REF       the kotlin-fhir-engine ref to check out (defaults to
#                    pull/122/head, the open pull request that adds codelabs/,
#                    set it to main once that pull request merges)
#   INSTALL_DESKTOP  set it to install ubuntu-desktop-minimal on a server image
#   SKIP_UPGRADE     set it to skip apt-get upgrade

set -euo pipefail
trap 'die "failed at line $LINENO while running $BASH_COMMAND"' ERR

LEARNER_USER="${LEARNER_USER:-}"
ENGINE_REF="${ENGINE_REF:-pull/122/head}"
export DEBIAN_FRONTEND=noninteractive

# Desktop images run unattended-upgrades soon after boot. Wait for its dpkg
# lock instead of failing on it.
APT=(apt-get -o DPkg::Lock::Timeout=600)

# Android SDK command-line tools 19.0, checksum taken from the download.
CMDLINE_TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip"
CMDLINE_TOOLS_SHA256="7ec965280a073311c339e571cd5de778b9975026cfcbe79f2b1cdcb1e15317ee"

# The codelabs use AGP 8.13.0 with compileSdk 36.
SDK_PACKAGES=("platforms;android-36" "build-tools;36.0.0" "platform-tools")

# The images in kotlin-fhir-engine/codelabs/docker-compose.yml.
DOCKER_IMAGES=("hapiproject/hapi:v8.12.0-2" "curlimages/curl:8.11.1")

DATA_CAPTURE_REPO="https://github.com/ohs-foundation/kotlin-fhir-data-capture.git"
ENGINE_REPO="https://github.com/ohs-foundation/kotlin-fhir-engine.git"

CODENAME=""
LEARNER_HOME=""
ANDROID_SDK=""
CODELABS_DIR=""
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

# Run a command as the learner, so everything in their home stays theirs.
as_learner() {
    runuser -u "$LEARNER_USER" -- env HOME="$LEARNER_HOME" ANDROID_HOME="$ANDROID_SDK" "$@"
}

# --- 1. preflight -----------------------------------------------------------

resolve_learner() {
    if [ -z "$LEARNER_USER" ]; then
        LEARNER_USER="${SUDO_USER:-}"
    fi
    if [ -z "$LEARNER_USER" ] && command -v logname >/dev/null 2>&1; then
        LEARNER_USER="$(logname 2>/dev/null || true)"
    fi

    [ -n "$LEARNER_USER" ] && [ "$LEARNER_USER" != "root" ] \
        || die "no learner account resolved, so run it with sudo from that account or set LEARNER_USER"
    id "$LEARNER_USER" >/dev/null 2>&1 || die "user '$LEARNER_USER' does not exist"

    LEARNER_HOME="$(getent passwd "$LEARNER_USER" | cut -d: -f6)"
    [ -d "$LEARNER_HOME" ] || die "home folder of '$LEARNER_USER' not found"

    ANDROID_SDK="$LEARNER_HOME/Android/Sdk"
    CODELABS_DIR="$LEARNER_HOME/codelabs"
}

preflight() {
    log "=== preflight ==="

    [ "$(id -u)" -eq 0 ] || die "must run as root, so try sudo $0"
    [ -r /etc/os-release ] || die "/etc/os-release is not readable, so this is probably not Ubuntu"

    # shellcheck disable=SC1091
    . /etc/os-release
    CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    [ -n "$CODENAME" ] || die "could not determine the Ubuntu codename"
    [ "$(dpkg --print-architecture)" = "amd64" ] \
        || die "the Android SDK tools and the codelabs' desktop builds need amd64"
    log "detected ${PRETTY_NAME:-unknown} (codename $CODENAME)"

    resolve_learner
    log "learner account is $LEARNER_USER, with the SDK in $ANDROID_SDK and the code in $CODELABS_DIR"

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

# --- 2. desktop and base packages -------------------------------------------

install_base() {
    log "=== base packages ==="

    # The Desktop versions of the codelab apps open a window, and the Web
    # versions and the HAPI check run in a browser on the VM.
    if [ -n "${INSTALL_DESKTOP:-}" ]; then
        apt_install ubuntu-desktop-minimal
        REBOOT_REQUIRED=1
    elif ! pkg_installed ubuntu-desktop-minimal && ! pkg_installed ubuntu-desktop; then
        warn "no Ubuntu desktop found, so the codelab apps have nowhere to open, set INSTALL_DESKTOP=1 to add one"
    fi

    # The engine codelab sets jvmToolchain(21) and the FHIRPath JVM artifacts
    # need Java 21. unzip unpacks the SDK tools. Git 2.25 or later does the
    # sparse checkout.
    apt_install ca-certificates curl git unzip openjdk-21-jdk firefox
}

# --- 3. docker --------------------------------------------------------------
# https://docs.docker.com/engine/install/ubuntu/#install-using-the-repository
# The engine codelab starts HAPI FHIR with docker compose.

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
        apt_install docker-ce docker-ce-cli containerd.io docker-compose-plugin
    else
        log "docker-ce is already installed"
    fi

    systemctl enable --now docker

    if id -nG "$LEARNER_USER" | tr ' ' '\n' | grep -qx docker; then
        log "user '$LEARNER_USER' is already in the docker group"
    else
        log "adding user '$LEARNER_USER' to the docker group"
        usermod -aG docker "$LEARNER_USER"
    fi

    local image
    for image in "${DOCKER_IMAGES[@]}"; do
        if docker image inspect "$image" >/dev/null 2>&1; then
            log "image $image is already pulled"
        else
            log "pulling $image"
            docker pull "$image"
        fi
    done
}

# --- 4. android sdk ---------------------------------------------------------
# Android Studio is not needed, but the Android Gradle Plugin will not
# configure the projects without an SDK, even for desktop and web tasks.

install_android_sdk() {
    log "=== android sdk ==="

    local sdkmanager="$ANDROID_SDK/cmdline-tools/latest/bin/sdkmanager"

    if [ -x "$sdkmanager" ]; then
        log "the Android command-line tools are already installed"
    else
        local tmp
        tmp="$(mktemp -d)"
        log "downloading the Android command-line tools"
        curl -fsSL "$CMDLINE_TOOLS_URL" -o "$tmp/cmdline-tools.zip"
        echo "$CMDLINE_TOOLS_SHA256  $tmp/cmdline-tools.zip" | sha256sum -c --quiet - \
            || die "the Android command-line tools download does not match its checksum"
        unzip -q "$tmp/cmdline-tools.zip" -d "$tmp"

        # sdkmanager only runs from cmdline-tools/latest.
        install -d -o "$LEARNER_USER" -g "$LEARNER_USER" \
            "$LEARNER_HOME/Android" "$ANDROID_SDK" "$ANDROID_SDK/cmdline-tools"
        mv "$tmp/cmdline-tools" "$ANDROID_SDK/cmdline-tools/latest"
        chown -R "$LEARNER_USER:$LEARNER_USER" "$ANDROID_SDK/cmdline-tools/latest"
        rm -rf "$tmp"
    fi

    # Accepted licences also let AGP download a build-tools version it prefers.
    log "accepting the Android SDK licences"
    yes | as_learner "$sdkmanager" --licenses >/dev/null || true

    log "installing ${SDK_PACKAGES[*]}"
    as_learner "$sdkmanager" "${SDK_PACKAGES[@]}" >/dev/null

    tee /etc/profile.d/android-sdk.sh >/dev/null <<EOF
export ANDROID_HOME="$ANDROID_SDK"
export PATH="\$ANDROID_HOME/cmdline-tools/latest/bin:\$ANDROID_HOME/platform-tools:\$PATH"
EOF
}

# --- 5. codelab checkouts ---------------------------------------------------

clone_codelabs() {
    log "=== codelabs ==="

    as_learner mkdir -p "$CODELABS_DIR"

    local dc="$CODELABS_DIR/kotlin-fhir-data-capture"
    if [ -d "$dc/.git" ]; then
        log "kotlin-fhir-data-capture is already cloned"
    else
        log "cloning the codelabs folder of kotlin-fhir-data-capture"
        as_learner git clone --quiet --depth 1 --filter=blob:none --sparse "$DATA_CAPTURE_REPO" "$dc"
        as_learner git -C "$dc" sparse-checkout set codelabs gradle
    fi

    local engine="$CODELABS_DIR/kotlin-fhir-engine"
    if [ -d "$engine/.git" ]; then
        log "kotlin-fhir-engine is already cloned"
    else
        log "cloning kotlin-fhir-engine at $ENGINE_REF"
        as_learner git clone --quiet --depth 1 --filter=blob:none "$ENGINE_REPO" "$engine"
        as_learner git -C "$engine" fetch --quiet --depth 1 origin "$ENGINE_REF"
        as_learner git -C "$engine" checkout --quiet FETCH_HEAD
    fi

    # An IDE started from the desktop menu may not read /etc/profile.d, so
    # each project also names the SDK itself.
    local dir
    for dir in "$dc/codelabs" "$engine/codelabs"; do
        [ -d "$dir" ] || die "$dir is missing, so check ENGINE_REF and the repository layout"
        as_learner sh -c "echo 'sdk.dir=$ANDROID_SDK' > '$dir/local.properties'"
    done
}

# --- 6. summary -------------------------------------------------------------

summary() {
    [ -f /var/run/reboot-required ] && REBOOT_REQUIRED=1

    cat <<EOF

============================================================
 Provisioning complete
============================================================

  java        $({ java -version 2>&1 || echo 'not reporting a version'; } | head -1)
  sdkmanager  $(as_learner "$ANDROID_SDK/cmdline-tools/latest/bin/sdkmanager" --version 2>/dev/null || echo 'not reporting a version')
  docker      $(docker --version 2>/dev/null || echo 'not reporting a version')
  compose     $(docker compose version --short 2>/dev/null || echo 'not reporting a version')
  git         $(git --version 2>/dev/null || echo 'not reporting a version')
  codelabs    $CODELABS_DIR
  engine ref  $ENGINE_REF

Next steps

  1. Log out and back in as $LEARNER_USER, so the docker group and
     ANDROID_HOME take effect. Check with docker run --rm hello-world

  2. Install IntelliJ IDEA with the Kotlin Multiplatform plugin, then
     warm the Gradle cache from the desktop. See steps 5 and 7 of
     .claude/codelabs-on-heropa.md.
EOF

    if [ "$REBOOT_REQUIRED" -eq 1 ]; then
        cat <<'EOF'

  A reboot is pending after a kernel, libc or desktop install. Reboot
  before saving the template.

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
    install_android_sdk
    clone_codelabs
    summary
}

main "$@"
