#!/usr/bin/env bash
#
# bc250-steamos-prep.sh
#
# SteamOS-specific prep for lonewolf0622/BC-250-Mesh-Shader-Patch (driconf edition).
# The upstream repo's bc250-rebuild.sh targets CachyOS/Bazzite, which ship a full
# Arch dev toolchain. SteamOS's base image strips out several dev headers and
# pkg-config (.pc) files that Mesa's build needs, even though the runtime
# libraries themselves are present. This script:
#
#   1. Disables SteamOS's read-only root so packages can actually install
#   2. Initializes pacman keys (needed on a fresh/frozen SteamOS install)
#   3. Detects and patches in missing dev headers for packages SteamOS ships
#      as runtime-only (currently known: elfutils/libelf, zlib, zstd)
#   4. Points Meson's temp build dir off /tmp, since noexec on /tmp causes
#      cryptic "Could not get define" failures during configure
#   5. Hands off to the real bc250-rebuild.sh
#
# Usage:
#   chmod +x bc250-steamos-prep.sh
#   ./bc250-steamos-prep.sh
#
# Requires bc250-rebuild.sh, bc250_driconf_fix.patch, bc250-add-game.sh, and
# bc250-doctor.sh to already be downloaded into the same directory (or ~/Downloads).

set -uo pipefail

log()  { echo -e "\033[1;36m[prep]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*"; }
err()  { echo -e "\033[1;31m[fail]\033[0m $*"; }

# Locate the rebuild script (same dir as this script, or ~/Downloads)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REBUILD_SCRIPT=""
for candidate in "$SCRIPT_DIR/bc250-rebuild.sh" "$HOME/Downloads/bc250-rebuild.sh"; do
    if [[ -f "$candidate" ]]; then
        REBUILD_SCRIPT="$candidate"
        break
    fi
done
if [[ -z "$REBUILD_SCRIPT" ]]; then
    err "Could not find bc250-rebuild.sh next to this script or in ~/Downloads."
    err "Download it from the BC-250-Mesh-Shader-Patch repo first."
    exit 1
fi
log "Found rebuild script: $REBUILD_SCRIPT"

# ---------------------------------------------------------------------------
# 1. Read-only root
# ---------------------------------------------------------------------------
if command -v steamos-readonly &>/dev/null; then
    STATE="$(steamos-readonly status 2>/dev/null || echo unknown)"
    if [[ "$STATE" == "enabled" ]]; then
        log "Disabling SteamOS read-only root..."
        sudo steamos-readonly disable
    else
        log "Read-only root already disabled (or status unknown: $STATE)."
    fi
else
    log "steamos-readonly not found — assuming this isn't SteamOS, or root is already writable."
fi

# ---------------------------------------------------------------------------
# 2. Pacman keys
# ---------------------------------------------------------------------------
if [[ ! -d /etc/pacman.d/gnupg ]]; then
    log "Initializing pacman keyring..."
    sudo pacman-key --init
    sudo pacman-key --populate archlinux holo 2>/dev/null || sudo pacman-key --populate archlinux
else
    log "Pacman keyring already initialized."
fi

# ---------------------------------------------------------------------------
# 3. Fetch a missing dev package (headers + .so + .pc) straight from the
#    Arch mirror, bypassing SteamOS's stripped-down package build.
#    Looks up the exact current filename from core.db so we don't guess
#    version/epoch formatting.
# ---------------------------------------------------------------------------
fetch_arch_pkg() {
    local pkgname="$1"
    local workdir
    workdir="$(mktemp -d)"

    log "Fetching current '$pkgname' package metadata from Arch mirror..."
    if ! curl -fsSL "https://geo.mirror.pkgbuild.com/core/os/x86_64/core.db" -o "$workdir/core.db"; then
        err "Could not download core.db"
        rm -rf "$workdir"
        return 1
    fi

    local entry
    entry="$(tar -tf "$workdir/core.db" | grep -E "^${pkgname}-[^/]+/$" | sort -V | tail -n1)"
    if [[ -z "$entry" ]]; then
        err "Could not find '$pkgname' in core.db listing."
        rm -rf "$workdir"
        return 1
    fi
    entry="${entry%/}"

    local filename
    filename="$(tar -xf "$workdir/core.db" -O "$entry/desc" | grep -A1 '%FILENAME%' | tail -n1)"
    if [[ -z "$filename" ]]; then
        err "Could not resolve filename for '$pkgname'."
        rm -rf "$workdir"
        return 1
    fi

    log "Downloading $filename..."
    if ! curl -fsSL "https://geo.mirror.pkgbuild.com/core/os/x86_64/$filename" -o "$workdir/$filename"; then
        err "Download failed for $filename"
        rm -rf "$workdir"
        return 1
    fi

    mkdir -p "$workdir/extract"
    tar -xf "$workdir/$filename" -C "$workdir/extract"

    if [[ -d "$workdir/extract/usr/include" ]]; then
        sudo cp -rn "$workdir/extract/usr/include/." /usr/include/
    fi
    if [[ -d "$workdir/extract/usr/lib" ]]; then
        sudo cp -rn "$workdir/extract/usr/lib/." /usr/lib/
    fi

    rm -rf "$workdir"
    return 0
}

ensure_dev_pkg() {
    # $1 = pkg-config module name to test, $2 = arch package name to fetch if missing
    local pc_name="$1"
    local pkg_name="$2"

    if pkg-config --exists "$pc_name" 2>/dev/null; then
        log "$pc_name already resolves via pkg-config — skipping."
        return 0
    fi

    warn "$pc_name not found via pkg-config. Trying pacman first..."
    if sudo pacman -S --needed --noconfirm "$pkg_name" 2>/dev/null && pkg-config --exists "$pc_name" 2>/dev/null; then
        log "$pc_name resolved after installing $pkg_name via pacman."
        return 0
    fi

    warn "pacman didn't provide dev headers for $pkg_name (SteamOS often ships runtime-only builds)."
    warn "Pulling $pkg_name directly from the Arch mirror instead..."
    if fetch_arch_pkg "$pkg_name" && pkg-config --exists "$pc_name" 2>/dev/null; then
        log "$pc_name resolved after manual install."
        return 0
    fi

    err "Could not resolve $pc_name. You may need to handle this one manually."
    return 1
}

log "Checking known problem dependencies (elfutils/libelf, zlib, zstd)..."
ensure_dev_pkg "libelf"   "libelf"
ensure_dev_pkg "zlib"     "zlib"
ensure_dev_pkg "libzstd"  "zstd"

# Other common gaps seen on a bare SteamOS install — installed via pacman only,
# since these packages weren't found to be stripped (unlike the three above).
log "Installing other required dev packages via pacman (if missing)..."
sudo pacman -S --needed --noconfirm \
    ninja python-mako python-yaml \
    wayland wayland-protocols libffi \
    libxau libxdmcp xorgproto libxcb \
    xcb-util xcb-util-wm xcb-util-keysyms xcb-util-renderutil xcb-util-image \
    libx11 libxext libxdamage libxfixes libxrandr libxshmfence libxxf86vm libxrender \
    2>&1 | grep -v "^warning: .* is up to date" || true

# ---------------------------------------------------------------------------
# 4. TMPDIR fix for Meson (avoids noexec /tmp breaking compiler checks)
# ---------------------------------------------------------------------------
export TMPDIR="$HOME/mesa-tmp"
mkdir -p "$TMPDIR"
log "TMPDIR set to $TMPDIR for this session."

# ---------------------------------------------------------------------------
# 5. Hand off to the real rebuild script
# ---------------------------------------------------------------------------
log "Handing off to bc250-rebuild.sh..."
log "(If this fails on a dependency not listed above, check the error, install"
log " the missing piece, then just rerun this prep script — it's idempotent.)"
echo
cd "$HOME" || exit 1
bash "$REBUILD_SCRIPT" "$@"
