#!/bin/bash

# ASUS Linux Tools Update Script for Linux Mint 22.3
# Version: 22.3.2
#
# Updates an existing asusctl installation to the latest tagged release from
# https://github.com/OpenGamingCollective/asusctl
#
# Upstream publishes release tags but only ships Arch Linux binary packages, so
# this script builds the pinned tag from source, stages it with the upstream
# Makefile, wraps the staged tree in a .deb, and installs it with apt. dpkg then
# owns the files, which gives us version tracking, clean upgrades (files dropped
# upstream are removed instead of lingering), and rollback to a cached .deb.
#
# Requirements:
# - Linux Mint 22.3 (Cinnamon, MATE, or Xfce edition)
# - Sudo privileges
# - Build dependencies from install-asus-linux.sh (Rust toolchain, dev headers)
#
# Usage:
#   ./update-asus-linux.sh              # update to the latest release tag
#   ./update-asus-linux.sh --check      # report only, change nothing
#   ./update-asus-linux.sh --tag 6.3.10 # build a specific tag
#   ./update-asus-linux.sh --rollback   # reinstall the previous cached .deb
#   ./update-asus-linux.sh --install-timer   # weekly "update available" check
#
# To use a custom build directory:
#   ASUS_BUILD_DIR="/path/to/custom/dir" ./update-asus-linux.sh
#
# For more information, visit: https://asus-linux.org/

set -euo pipefail

# Packaged files and directories must not inherit a permissive user umask
# (Mint defaults to 002, which would ship group-writable 0775 directories).
umask 022

# Script configuration
SCRIPT_VERSION="22.3.2"
PKG_NAME="asusctl-ogc"
UPSTREAM_REPO="https://github.com/OpenGamingCollective/asusctl.git"
UPSTREAM_URL="https://github.com/OpenGamingCollective/asusctl"

# Set working directory (can be overridden with ASUS_BUILD_DIR environment variable)
BASE_DIR="${ASUS_BUILD_DIR:-$HOME/.local/src/asus-linux}"
SRC_DIR="$BASE_DIR/asusctl"
CACHE_DIR="/var/cache/asus-linux-mint"

# Optional: build ROG Control Center GUI (same switch as the installer)
INSTALL_ROG_GUI="${ASUS_INSTALL_ROG_GUI:-1}"

# Runtime flags (set by parse_args)
MODE="update"
REQUESTED_TAG=""
ASSUME_YES=0
NOTIFY=0
STAGE_DIR=""

# Function for colored output
print_status() {
    echo -e "\e[32m[INFO]\e[0m $1"
}

print_error() {
    echo -e "\e[31m[ERROR]\e[0m $1" >&2
}

print_warning() {
    echo -e "\e[33m[WARNING]\e[0m $1"
}

print_success() {
    echo -e "\e[92m[SUCCESS]\e[0m $1"
}

print_header() {
    echo -e "\e[1;34m"
    echo "========================================"
    echo "  ASUS Linux Tools Update Script"
    echo "  Version $SCRIPT_VERSION"
    echo "========================================"
    echo -e "\e[0m"
}

# Remove the staging directory on exit; the built .deb lives in the cache
cleanup() {
    local exit_code=$?
    if [ -n "$STAGE_DIR" ] && [ -d "$STAGE_DIR" ]; then
        rm -rf "$STAGE_DIR"
    fi
    if [ $exit_code -ne 0 ] && [ "$MODE" = "update" ]; then
        print_error "Update failed. Your current installation was left untouched."
        print_error "Build directory: $SRC_DIR"
    fi
    exit $exit_code
}

trap cleanup EXIT

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTION]...

Update asusctl to the latest tagged release from the OpenGamingCollective
repository, packaged as a .deb so that apt/dpkg manage the installation.

Options:
  --check            Report installed and latest versions, then exit.
                     Exit code 0 = up to date, 10 = update available.
  --tag TAG          Build a specific upstream tag (e.g. 6.3.10) instead of
                     the latest release. Downgrades are allowed.
  --rollback         Reinstall the previous .deb from $CACHE_DIR.
  --no-gui           Skip rog-control-center (equivalent to ASUS_INSTALL_ROG_GUI=0).
  --yes, -y          Do not prompt for confirmation.
  --notify           With --check, also send a desktop notification.
  --install-timer    Install a weekly user systemd timer that checks for
                     updates and notifies. It never builds or installs.
  --remove-timer     Remove the weekly check timer.
  --help, -h         Show this help.

Environment:
  ASUS_BUILD_DIR         Build directory (default: \$HOME/.local/src/asus-linux)
  ASUS_INSTALL_ROG_GUI   Set to 0 to skip the GUI build (default: 1)
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --check)         MODE="check" ;;
            --rollback)      MODE="rollback" ;;
            --install-timer) MODE="install-timer" ;;
            --remove-timer)  MODE="remove-timer" ;;
            --tag)
                if [ $# -lt 2 ]; then
                    print_error "--tag requires an argument."
                    exit 1
                fi
                REQUESTED_TAG="$2"
                shift
                ;;
            --no-gui)        INSTALL_ROG_GUI=0 ;;
            --yes|-y)        ASSUME_YES=1 ;;
            --notify)        NOTIFY=1 ;;
            --help|-h)       usage; exit 0 ;;
            *)
                print_error "Unknown option: $1"
                usage >&2
                exit 1
                ;;
        esac
        shift
    done
}

confirm() {
    local prompt="$1"
    if [ "$ASSUME_YES" -eq 1 ]; then
        return 0
    fi
    read -p "$prompt (y/N): " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

# Check basic preconditions
check_system() {
    if [ "$EUID" -eq 0 ]; then
        print_error "This script should not be run as root. Run as a regular user with sudo access."
        exit 1
    fi

    local required=(git curl dpkg-deb)
    local missing=()
    local cmd
    for cmd in "${required[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        print_error "Missing required commands: ${missing[*]}"
        print_error "Install them with: sudo apt install git curl dpkg-dev"
        exit 1
    fi
}

# Make cargo available; the installer puts it in ~/.cargo
ensure_rust() {
    if ! command -v cargo &> /dev/null && [ -f "$HOME/.cargo/env" ]; then
        # shellcheck disable=SC1091
        source "$HOME/.cargo/env"
    fi

    if ! command -v cargo &> /dev/null; then
        print_error "cargo not found. Run install-asus-linux.sh first to set up the build environment."
        exit 1
    fi
}

# Version currently installed, as dpkg sees it. Empty if not packaged.
get_installed_version() {
    dpkg-query -W -f='${Version}' "$PKG_NAME" 2>/dev/null || true
}

# True when asusctl is present on disk but not owned by our package, i.e. it was
# installed by the pre-.deb version of install-asus-linux.sh
has_legacy_install() {
    [ -z "$(get_installed_version)" ] && [ -x /usr/bin/asusctl ]
}

# Latest upstream release tag. git ls-remote avoids the GitHub API rate limit and
# needs no JSON parsing. Only x.y.z tags are considered; upstream also carries
# some unrelated v1.0.x tags that must not be treated as releases.
get_latest_tag() {
    git ls-remote --tags --refs "$UPSTREAM_REPO" 2>/dev/null \
        | awk '{print $2}' \
        | sed 's#refs/tags/##' \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort -V \
        | tail -n 1
}

# Clone on first run, otherwise fetch. Never discards a dirty tree silently.
sync_source() {
    mkdir -p "$BASE_DIR"

    if [ ! -d "$SRC_DIR/.git" ]; then
        print_status "Cloning asusctl repository into $SRC_DIR..."
        git clone "$UPSTREAM_REPO" "$SRC_DIR"
        return
    fi

    print_status "Fetching upstream tags..."
    git -C "$SRC_DIR" fetch --tags --prune origin
}

# Check out the requested tag as a detached HEAD so the build is reproducible
checkout_tag() {
    local tag="$1"

    if [ -n "$(git -C "$SRC_DIR" status --porcelain)" ]; then
        print_warning "Local modifications found in $SRC_DIR; they will be discarded."
        if ! confirm "Discard local changes and continue?"; then
            print_status "Update cancelled by user."
            exit 0
        fi
        git -C "$SRC_DIR" reset --hard
        git -C "$SRC_DIR" clean -fd
    fi

    print_status "Checking out tag $tag..."
    git -C "$SRC_DIR" checkout --detach --quiet "refs/tags/$tag"
}

# Build the workspace.
#
# Note: no --locked here. Upstream does not commit a Cargo.lock and disabled
# --locked in their own Makefile on 2026-07-18, so passing it fails the build.
build_source() {
    print_status "Building asusctl (this may take several minutes)..."

    if [ "$INSTALL_ROG_GUI" = "1" ]; then
        # X11=1 adds the x11 feature; Linux Mint desktops commonly run X11 and
        # the GUI panics at runtime without it.
        make -C "$SRC_DIR" build X11=1
    else
        print_status "Skipping rog-control-center (GUI) build."
        cargo build --release --manifest-path "$SRC_DIR/Cargo.toml" \
            -p asusctl -p asusd -p asusd-user -p asus-shutdown
    fi
}

# Stage the build into a DESTDIR tree using upstream's own install rules, so the
# file list follows upstream instead of drifting from it.
stage_install() {
    STAGE_DIR="$(mktemp -d -t asusctl-stage-XXXXXX)"
    # install-data-asusd resolves DESTDIR with realpath, so it must exist first.
    # mktemp creates the directory 0700; that mode would end up on the package's
    # own root entry, so reset it to the standard 0755.
    mkdir -p "$STAGE_DIR"
    chmod 0755 "$STAGE_DIR"

    print_status "Staging files into a temporary package root..."

    local targets=(install-asusd install-asus-shutdown install-asusctl install-asusd_user)
    if [ "$INSTALL_ROG_GUI" = "1" ]; then
        targets+=(install-rog_gui install-data-rog_gui)
    fi
    targets+=(install-data-asusd)

    # Individual targets rather than the aggregate `install` target, which always
    # pulls in rog_gui and would force a GUI build even with --no-gui.
    make -C "$SRC_DIR" "${targets[@]}" DESTDIR="$STAGE_DIR" prefix=/usr

    # install-data-asusd_user is declared .PHONY upstream but carries no recipe,
    # so make reports "nothing to be done" and the user unit is never installed
    # even though data/ ships it. Install it ourselves.
    install -D -m 0644 "$SRC_DIR/data/asusd-user.service" \
        "$STAGE_DIR/usr/lib/systemd/user/asusd-user.service"

    install -D -m 0644 "$SRC_DIR/LICENSE" "$STAGE_DIR/usr/share/asusctl/LICENSE"
}

# Resolve shared library dependencies from the built binaries. Falls back to a
# conservative list if dpkg-shlibdeps is unavailable or unhappy.
resolve_depends() {
    local fallback="libc6, libgcc-s1, libudev1, libdbus-1-3, libssl3 | libssl3t64"
    local shlibdeps_dir binaries depends

    if ! command -v dpkg-shlibdeps &> /dev/null; then
        echo "$fallback"
        return
    fi

    mapfile -t binaries < <(find "$STAGE_DIR/usr/bin" -type f 2>/dev/null)
    if [ ${#binaries[@]} -eq 0 ]; then
        echo "$fallback"
        return
    fi

    # dpkg-shlibdeps insists on being run from a tree containing debian/control
    shlibdeps_dir="$(mktemp -d -t asusctl-shlibdeps-XXXXXX)"
    mkdir -p "$shlibdeps_dir/debian"
    cat > "$shlibdeps_dir/debian/control" <<EOF
Source: $PKG_NAME
Package: $PKG_NAME
Architecture: any
EOF

    depends="$(cd "$shlibdeps_dir" && dpkg-shlibdeps -O --ignore-missing-info "${binaries[@]}" 2>/dev/null \
        | sed -n 's/^shlibs:Depends=//p')"
    rm -rf "$shlibdeps_dir"

    if [ -n "$depends" ]; then
        echo "$depends"
    else
        echo "$fallback"
    fi
}

# Write DEBIAN/ control and maintainer scripts into the staged tree
write_package_metadata() {
    local version="$1"
    local arch depends installed_size debian_dir

    arch="$(dpkg --print-architecture)"
    depends="$(resolve_depends)"
    installed_size="$(du -ks "$STAGE_DIR" | cut -f1)"
    debian_dir="$STAGE_DIR/DEBIAN"
    mkdir -p "$debian_dir"

    cat > "$debian_dir/control" <<EOF
Package: $PKG_NAME
Version: $version
Architecture: $arch
Maintainer: asus-linux-mint <https://github.com/farfalk/asus-linux-mint>
Installed-Size: $installed_size
Depends: $depends
Section: utils
Priority: optional
Homepage: $UPSTREAM_URL
Provides: asusctl
Conflicts: asusctl
Replaces: asusctl
Description: Laptop feature control for ASUS ROG and TUF laptops
 asusctl, asusd and rog-control-center built from the OpenGamingCollective
 asusctl release $version.
 .
 This package was built locally from source by update-asus-linux.sh; it is not
 an official Debian or upstream package.
EOF

    # /etc/asusd is deliberately not shipped in the package: it holds user fan
    # curves, profiles and LED settings, and must survive upgrade and removal.
    cat > "$debian_dir/preinst" <<'EOF'
#!/bin/sh
set -e

# On first install, clear files left by the pre-.deb installer that this
# package does not ship, so they do not linger unowned. Paths the package does
# own are simply overwritten by dpkg.
if [ "$1" = "install" ] && [ -z "$2" ]; then
    rm -f /usr/share/applications/rog-control-center.desktop
    rm -f /usr/local/bin/asusctl /usr/local/bin/asusd \
          /usr/local/bin/asusd-user /usr/local/bin/rog-control-center
fi

exit 0
EOF

    cat > "$debian_dir/postinst" <<'EOF'
#!/bin/sh
set -e

if [ "$1" = "configure" ]; then
    # asusd.service uses ProtectSystem=strict with ReadWritePaths=/etc/asusd/.
    # systemd refuses to start the unit (exit 226/NAMESPACE) if it is missing.
    install -d -m 0755 /etc/asusd

    systemctl daemon-reload || true
    udevadm control --reload-rules || true
    gtk-update-icon-cache /usr/share/icons/hicolor/ 2>/dev/null || true

    # asusd.service has no [Install] section: it is Type=dbus with a BusName and
    # is therefore D-Bus activated and "static". enable/disable do not apply.
    if [ -z "$2" ]; then
        # Fresh install. Note this also covers taking over an unmanaged install,
        # where an old asusd is already running: "start" would be a no-op and
        # leave the previous binary serving D-Bus, so restart unconditionally.
        # restart also starts the unit when it is not running.
        systemctl restart asusd.service || true
    else
        # Upgrade: only restart if it was already running
        systemctl try-restart asusd.service || true
    fi
fi

exit 0
EOF

    cat > "$debian_dir/prerm" <<'EOF'
#!/bin/sh
set -e

if [ "$1" = "remove" ]; then
    # No disable: the unit is static (D-Bus activated), so it is never enabled.
    systemctl stop asusd.service || true
fi

exit 0
EOF

    cat > "$debian_dir/postrm" <<'EOF'
#!/bin/sh
set -e

if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    systemctl daemon-reload || true
    udevadm control --reload-rules || true
fi

exit 0
EOF

    chmod 0755 "$debian_dir/preinst" "$debian_dir/postinst" \
        "$debian_dir/prerm" "$debian_dir/postrm"
}

# Build the .deb into the cache directory and echo its path
build_deb() {
    local version="$1"
    local arch deb_path

    arch="$(dpkg --print-architecture)"
    deb_path="$CACHE_DIR/${PKG_NAME}_${version}_${arch}.deb"

    sudo install -d -m 0755 "$CACHE_DIR"
    print_status "Building package ${PKG_NAME}_${version}_${arch}.deb..." >&2
    sudo dpkg-deb --build --root-owner-group "$STAGE_DIR" "$deb_path" >&2

    echo "$deb_path"
}

install_deb() {
    local deb_path="$1"

    print_status "Installing $(basename "$deb_path")..."
    sudo apt install -y --allow-downgrades "$deb_path"
}

# asusd-user.service is a user unit with an [Install] section, so unlike
# asusd.service it does need enabling. The package's postinst runs as root and
# cannot do that for the invoking user, so handle it here.
enable_user_service() {
    systemctl --user daemon-reload 2>/dev/null || true

    if ! systemctl --user list-unit-files 2>/dev/null | grep -q "^asusd-user\.service"; then
        print_warning "asusd-user.service is not visible in this session."
        print_warning "After the next login, enable it with:"
        print_warning "  systemctl --user enable --now asusd-user.service"
        return 0
    fi

    systemctl --user enable asusd-user.service 2>/dev/null || true
    systemctl --user restart asusd-user.service 2>/dev/null || true
    print_status "asusd-user.service enabled and restarted for $USER."
}

# Keep the three most recent packages so rollback has something to fall back to
prune_cache() {
    local keep=3
    local old

    [ -d "$CACHE_DIR" ] || return 0

    mapfile -t old < <(find "$CACHE_DIR" -maxdepth 1 -name "${PKG_NAME}_*.deb" -printf '%T@ %p\n' \
        | sort -rn | tail -n +$((keep + 1)) | cut -d' ' -f2-)

    if [ ${#old[@]} -gt 0 ]; then
        print_status "Pruning ${#old[@]} old cached package(s)..."
        sudo rm -f "${old[@]}"
    fi
}

report_versions() {
    local installed="$1"
    local latest="$2"

    echo
    if [ -n "$installed" ]; then
        echo "  Installed: $installed"
    elif has_legacy_install; then
        echo "  Installed: unmanaged build (installed before .deb packaging)"
    else
        echo "  Installed: not installed"
    fi
    echo "  Latest:    $latest"
    echo "  Release:   $UPSTREAM_URL/releases/tag/$latest"
    echo
}

notify_update() {
    local latest="$1"
    command -v notify-send &> /dev/null || return 0
    notify-send --app-name="ASUS Linux Tools" \
        "asusctl $latest available" \
        "Run update-asus-linux.sh to build and install it." 2>/dev/null || true
}

do_check() {
    local installed latest

    installed="$(get_installed_version)"
    latest="$(get_latest_tag)"

    if [ -z "$latest" ]; then
        print_error "Could not determine the latest release tag from $UPSTREAM_URL"
        exit 1
    fi

    report_versions "$installed" "$latest"

    if [ -n "$installed" ] && dpkg --compare-versions "$installed" ge "$latest"; then
        print_success "asusctl is up to date."
        return 0
    fi

    if [ -n "$installed" ]; then
        print_status "Update available: $installed -> $latest"
    else
        print_status "asusctl $latest is available to install."
    fi

    if [ "$NOTIFY" -eq 1 ]; then
        notify_update "$latest"
    fi

    return 10
}

do_update() {
    local installed latest target

    installed="$(get_installed_version)"

    if [ -n "$REQUESTED_TAG" ]; then
        target="$REQUESTED_TAG"
        print_status "Requested tag: $target"
    else
        print_status "Looking up the latest release tag..."
        target="$(get_latest_tag)"
        if [ -z "$target" ]; then
            print_error "Could not determine the latest release tag from $UPSTREAM_URL"
            exit 1
        fi
    fi

    report_versions "$installed" "$target"

    if [ -z "$REQUESTED_TAG" ] && [ -n "$installed" ] \
        && dpkg --compare-versions "$installed" ge "$target"; then
        print_success "asusctl is already up to date. Nothing to do."
        print_status "Use --tag to rebuild or install a specific version."
        return 0
    fi

    if has_legacy_install; then
        print_warning "An existing asusctl install was found that is not managed by dpkg."
        print_warning "It was installed directly by install-asus-linux.sh."
        print_warning "This update replaces it with the '$PKG_NAME' package, after which"
        print_warning "apt manages upgrades and removal. /etc/asusd is left untouched."
        echo
    fi

    if ! confirm "Build and install asusctl $target?"; then
        print_status "Update cancelled by user."
        return 0
    fi

    ensure_rust
    sync_source
    checkout_tag "$target"
    build_source
    stage_install
    write_package_metadata "$target"

    local deb_path
    deb_path="$(build_deb "$target")"
    install_deb "$deb_path"
    enable_user_service
    prune_cache

    echo
    print_success "asusctl updated to $target."
    show_post_update "$target"
}

do_rollback() {
    local installed candidates previous

    installed="$(get_installed_version)"

    if [ ! -d "$CACHE_DIR" ]; then
        print_error "No cached packages found in $CACHE_DIR"
        exit 1
    fi

    mapfile -t candidates < <(find "$CACHE_DIR" -maxdepth 1 -name "${PKG_NAME}_*.deb" -printf '%T@ %p\n' \
        | sort -rn | cut -d' ' -f2-)

    if [ ${#candidates[@]} -eq 0 ]; then
        print_error "No cached packages found in $CACHE_DIR"
        exit 1
    fi

    previous=""
    local deb deb_version
    for deb in "${candidates[@]}"; do
        deb_version="$(dpkg-deb -f "$deb" Version 2>/dev/null || true)"
        if [ -n "$deb_version" ] && [ "$deb_version" != "$installed" ]; then
            previous="$deb"
            break
        fi
    done

    if [ -z "$previous" ]; then
        print_error "No cached package older than the installed version ($installed) is available."
        print_status "Cached packages:"
        printf '  %s\n' "${candidates[@]}"
        exit 1
    fi

    print_status "Currently installed: ${installed:-none}"
    print_status "Rolling back to:     $(basename "$previous")"
    echo

    if ! confirm "Install $(basename "$previous")?"; then
        print_status "Rollback cancelled by user."
        return 0
    fi

    install_deb "$previous"
    print_success "Rolled back to $(dpkg-deb -f "$previous" Version)."
}

timer_unit_dir() {
    echo "$HOME/.config/systemd/user"
}

do_install_timer() {
    local unit_dir script_path
    unit_dir="$(timer_unit_dir)"
    script_path="$(readlink -f "$0")"

    mkdir -p "$unit_dir"

    cat > "$unit_dir/asus-linux-update-check.service" <<EOF
[Unit]
Description=Check for asusctl updates

[Service]
Type=oneshot
# Exit code 10 means "update available"; it is expected, not a failure.
SuccessExitStatus=0 10
ExecStart=$script_path --check --notify
EOF

    cat > "$unit_dir/asus-linux-update-check.timer" <<EOF
[Unit]
Description=Weekly asusctl update check

[Timer]
OnCalendar=weekly
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable --now asus-linux-update-check.timer

    print_success "Weekly update check installed."
    print_status "It only notifies; it never builds or installs anything."
    print_status "Check status with: systemctl --user status asus-linux-update-check.timer"
}

do_remove_timer() {
    local unit_dir
    unit_dir="$(timer_unit_dir)"

    systemctl --user disable --now asus-linux-update-check.timer 2>/dev/null || true
    rm -f "$unit_dir/asus-linux-update-check.timer" \
          "$unit_dir/asus-linux-update-check.service"
    systemctl --user daemon-reload 2>/dev/null || true

    print_success "Weekly update check removed."
}

show_post_update() {
    local version="$1"

    echo
    echo "=== ASUSCTL STATUS ==="
    if command -v asusctl &> /dev/null; then
        asusctl info 2>/dev/null || print_warning "Could not get asusctl status. The service may still be starting."
    fi

    echo
    echo "=== MANAGED BY APT ==="
    echo "• Installed version:  dpkg-query -W $PKG_NAME"
    echo "• Remove everything:  sudo apt remove $PKG_NAME"
    echo "• Roll back:          $(basename "$0") --rollback"
    echo "• Cached packages:    $CACHE_DIR"
    echo
    echo "• Release notes: $UPSTREAM_URL/releases/tag/$version"
    echo "• Your settings in /etc/asusd were preserved."
    print_warning "Some changes only take effect after a reboot."
}

main() {
    parse_args "$@"

    case "$MODE" in
        check)
            do_check
            ;;
        rollback)
            print_header
            check_system
            do_rollback
            ;;
        install-timer)
            print_header
            do_install_timer
            ;;
        remove-timer)
            print_header
            do_remove_timer
            ;;
        update)
            print_header
            print_status "asusctl updater for Linux Mint"
            print_status "Script version: $SCRIPT_VERSION"
            check_system
            do_update
            ;;
    esac
}

main "$@"
