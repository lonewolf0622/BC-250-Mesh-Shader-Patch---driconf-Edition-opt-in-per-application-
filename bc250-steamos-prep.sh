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
#   3. Individually installs AND verifies every library/dev package the
#      build needs — not a hardcoded shortlist. SteamOS's silent-write-
#      failure bug (pacman reports success but headers/.pc files never
#      actually land on disk) has hit a different, unpredictable package
#      each time this has been run, so every package gets the same
#      install → verify → self-heal-from-mirror-if-needed treatment
#   4. Installs glibc/linux-api-headers if errno.h is missing (the very
#      first error a fresh SteamOS install typically hits)
#   5. Installs the rest of the build toolchain (meson, ninja, bison, flex,
#      pkgconf, the Wayland/X11 dev packages, etc.)
#   6. Points Meson's temp build dir off /tmp, since noexec on /tmp causes
#      cryptic "Could not get define" failures during configure
#   7. Hands off to the real bc250-rebuild.sh
#   8. After the build, verifies the ICD JSON (radeon_driconf_icd.x86_64.json)
#      actually points to a real, built driver .so — and auto-fixes the path
#      if it's stale, rather than leaving that as a "fatal error" surprise
#      the next time a game tries to load it via VK_ICD_FILENAMES
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
#    Looks up the exact current filename so we don't guess version/epoch
#    formatting. The core/extra databases are downloaded once and cached
#    for the rest of the script, rather than re-fetched on every call.
# ---------------------------------------------------------------------------
PKGDB_DIR="$(mktemp -d)"
CORE_DB="$PKGDB_DIR/core.db"
EXTRA_DB="$PKGDB_DIR/extra.db"
trap 'rm -rf "$PKGDB_DIR"' EXIT

ensure_pkg_dbs() {
    if [[ ! -s "$CORE_DB" ]]; then
        log "Fetching current core/extra package databases..."
        curl -fsSL "https://geo.mirror.pkgbuild.com/core/os/x86_64/core.db" -o "$CORE_DB" 2>/dev/null
        curl -fsSL "https://geo.mirror.pkgbuild.com/extra/os/x86_64/extra.db" -o "$EXTRA_DB" 2>/dev/null
    fi
}

fetch_arch_pkg() {
    local pkgname="$1"
    local workdir
    workdir="$(mktemp -d)"

    ensure_pkg_dbs

    local db repo_url entry
    entry="$(tar -tf "$CORE_DB" 2>/dev/null | grep -E "^${pkgname}-[^/]+/$" | sort -V | tail -n1)"
    if [[ -n "$entry" ]]; then
        db="$CORE_DB"
        repo_url="https://geo.mirror.pkgbuild.com/core/os/x86_64"
    else
        entry="$(tar -tf "$EXTRA_DB" 2>/dev/null | grep -E "^${pkgname}-[^/]+/$" | sort -V | tail -n1)"
        if [[ -n "$entry" ]]; then
            db="$EXTRA_DB"
            repo_url="https://geo.mirror.pkgbuild.com/extra/os/x86_64"
        else
            err "Could not find '$pkgname' in core or extra repo listing."
            rm -rf "$workdir"
            return 1
        fi
    fi
    entry="${entry%/}"

    local filename
    filename="$(tar -xf "$db" -O "$entry/desc" | grep -A1 '%FILENAME%' | tail -n1)"
    if [[ -z "$filename" ]]; then
        err "Could not resolve filename for '$pkgname'."
        rm -rf "$workdir"
        return 1
    fi

    log "Downloading $filename..."
    if ! curl -fsSL "$repo_url/$filename" -o "$workdir/$filename"; then
        err "Download failed for $filename"
        rm -rf "$workdir"
        return 1
    fi

    local size
    size="$(stat -c%s "$workdir/$filename" 2>/dev/null || echo 0)"
    if [[ "$size" -lt 1000 ]]; then
        err "$pkgname download suspiciously small ($size bytes) - likely a 404."
        rm -rf "$workdir"
        return 1
    fi

    mkdir -p "$workdir/extract"
    tar -xf "$workdir/$filename" -C "$workdir/extract"

    if [[ -d "$workdir/extract/usr/include" ]]; then
        sudo cp -rn "$workdir/extract/usr/include/." /usr/include/
    fi
    mkdir -p "$workdir/extract"
    tar -xf "$workdir/$filename" -C "$workdir/extract"

    # Copy every subdirectory under usr/ that the package actually contains,
    # rather than a hardcoded short list. This matters because "any"-
    # architecture packages (like xorgproto) put their .pc files under
    # usr/share/pkgconfig instead of usr/lib/pkgconfig - a package with no
    # compiled library at all may have nothing under usr/lib whatsoever.
    # Hardcoding just include+lib silently dropped files for exactly this
    # kind of package.
    if [[ -d "$workdir/extract/usr" ]]; then
        for subdir in "$workdir/extract/usr"/*/; do
            [[ -d "$subdir" ]] || continue
            local name
            name="$(basename "$subdir")"
            sudo mkdir -p "/usr/$name"
            sudo cp -rn "$subdir." "/usr/$name/"
        done
    else
        warn "$pkgname's package archive has no usr/ directory at all - nothing to copy."
    fi

    rm -rf "$workdir"
    return 0
}

ensure_dev_pkg() {
    # $1 = pkg-config module name to test, $2 = arch package name to fetch if missing
    local pc_name="$1"
    local pkg_name="$2"

    # Deliberately using --cflags rather than --exists: --exists can report
    # success even when a package's private Requires (e.g. xau/xdmcp both
    # privately need xproto just for headers) are actually missing, since it
    # doesn't always fully walk that chain. --cflags forces pkg-config to
    # actually resolve the full dependency chain the same way meson's build
    # will, catching this class of false-positive before the build does.
    if pkg-config --cflags "$pc_name" &>/dev/null; then
        log "$pc_name already resolves via pkg-config — skipping."
        return 0
    fi

    warn "$pc_name not found via pkg-config. Trying pacman first..."
    if sudo pacman -S --needed --noconfirm "$pkg_name" 2>/dev/null && pkg-config --cflags "$pc_name" &>/dev/null; then
        log "$pc_name resolved after installing $pkg_name via pacman."
        return 0
    fi

    warn "pacman didn't provide dev headers for $pkg_name (SteamOS often ships runtime-only builds)."
    warn "Pulling $pkg_name directly from the Arch mirror instead..."
    if fetch_arch_pkg "$pkg_name" && pkg-config --cflags "$pc_name" &>/dev/null; then
        log "$pc_name resolved after manual install."
        return 0
    fi

    err "Could not resolve $pc_name. You may need to handle this one manually."
    return 1
}

# ---------------------------------------------------------------------------
# 3b. Missing glibc/kernel headers - the very first error most fresh SteamOS
#     installs hit ("fatal error: errno.h: No such file or directory"),
#     because the base image doesn't ship full glibc dev headers by default.
# ---------------------------------------------------------------------------
if [[ ! -f /usr/include/errno.h ]]; then
    warn "errno.h missing - installing glibc and linux-api-headers..."
    sudo pacman -S --needed --noconfirm glibc linux-api-headers
fi

# ---------------------------------------------------------------------------
# 3c. Build tools with no single verifiable header/pkg-config file - just
#     install these via pacman directly. If pacman silently fails to write
#     one of these, the actual build step will surface a clear "command not
#     found" error, which is unambiguous enough to act on without needing
#     the same per-file verification the library packages below get.
# ---------------------------------------------------------------------------
log "Installing build tools via pacman..."
sudo pacman -S --needed --noconfirm \
    gcc make patch git curl tar binutils fakeroot \
    meson ninja pkgconf bison flex \
    python-mako python-yaml \
    2>&1 | grep -v "^warning: .* is up to date" || true

# ---------------------------------------------------------------------------
# 3d. Library/dev packages - EVERY one of these gets individually verified
#     after installing, not just the few we happened to hit tonight. SteamOS's
#     silent-write-failure bug (pacman reports success, but the actual
#     headers/.pc files never land on disk) has hit a different, unpredictable
#     set of packages each time this has been tested - libelf, zlib, zstd,
#     libxkbcommon, libxinerama, libxcursor so far. Since there's no way to
#     know in advance which package will hit it for any given person's
#     SteamOS build, every package below is checked and self-healed the same
#     way, not just a hardcoded shortlist.
#
#     Format: "pkg-config-module-name:pacman-package-name"
# ---------------------------------------------------------------------------
LIBRARY_PACKAGES=(
    "libelf:libelf"
    "zlib:zlib"
    "libzstd:zstd"
    "libffi:libffi"
    "wayland-client:wayland"
    "wayland-protocols:wayland-protocols"
    "xproto:xorgproto"
    "xau:libxau"
    "xdmcp:libxdmcp"
    "xcb:libxcb"
    "x11:libx11"
    "xext:libxext"
    "xdamage:libxdamage"
    "xfixes:libxfixes"
    "xrandr:libxrandr"
    "xshmfence:libxshmfence"
    "xxf86vm:libxxf86vm"
    "xrender:libxrender"
)

log "Installing and verifying ${#LIBRARY_PACKAGES[@]} library/dev packages..."
FAILED_PACKAGES=()
for entry in "${LIBRARY_PACKAGES[@]}"; do
    pc_name="${entry%%:*}"
    pkg_name="${entry##*:}"
    if ! ensure_dev_pkg "$pc_name" "$pkg_name"; then
        FAILED_PACKAGES+=("$pkg_name")
    fi
done

# xcb-util and friends provide multiple small helper libraries without one
# single representative pkg-config name worth hardcoding a guess for -
# install them, but don't block on verification the way the list above does.
sudo pacman -S --needed --noconfirm \
    xcb-util xcb-util-wm xcb-util-keysyms xcb-util-renderutil xcb-util-image \
    2>&1 | grep -v "^warning: .* is up to date" || true

if [[ ${#FAILED_PACKAGES[@]} -gt 0 ]]; then
    warn "Could not fully resolve: ${FAILED_PACKAGES[*]}"
    warn "The build below may fail on these specifically - if it does, the"
    warn "error will name the missing header/module so you know what to search for."
else
    log "All library packages verified present."
fi

# ---------------------------------------------------------------------------
# 4. TMPDIR fix for Meson (avoids noexec /tmp breaking compiler checks)
#    Set early so it's active for any compiler checks the steps above trigger.
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
REBUILD_STATUS=$?

# ---------------------------------------------------------------------------
# 6. Verify the ICD JSON actually points at a real, built driver.
#    Fatal errors when launching a game via VK_ICD_FILENAMES are often not a
#    build failure at all - the JSON file exists but its "library_path"
#    points somewhere the .so never actually landed (a stale path from an
#    older build, a relative path that doesn't resolve from where a game
#    launches, etc). Catch that here instead of leaving it as a mystery
#    "fatal error" the next time a game tries to load the driver.
# ---------------------------------------------------------------------------
verify_icd_json() {
    local json_path
    json_path="$(find "$HOME" -maxdepth 1 -iname "*driconf_icd*.json" -o -maxdepth 1 -iname "*radeon*icd*.json" 2>/dev/null | head -n1)"

    if [[ -z "$json_path" ]]; then
        err "No ICD JSON found in $HOME (expected something like radeon_driconf_icd.x86_64.json)."
        err "The build may not have completed - check the output above for errors."
        return 1
    fi
    log "Found ICD JSON: $json_path"

    if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$json_path" 2>/dev/null; then
        err "$json_path is not valid JSON. Something went wrong writing it."
        return 1
    fi

    local lib_path
    lib_path="$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    print(data.get('ICD', {}).get('library_path', ''))
except Exception:
    pass
" "$json_path")"

    if [[ -z "$lib_path" ]]; then
        err "$json_path has no ICD.library_path field — can't determine which .so it expects."
        return 1
    fi

    # Resolve relative paths the same way the Vulkan loader does: relative
    # to the JSON file's own directory, not the current working directory.
    local resolved_path
    if [[ "$lib_path" = /* ]]; then
        resolved_path="$lib_path"
    else
        resolved_path="$(dirname "$json_path")/$lib_path"
    fi

    if [[ -f "$resolved_path" ]]; then
        log "ICD JSON's library_path resolves correctly: $resolved_path"
        return 0
    fi

    warn "ICD JSON points to '$lib_path', which doesn't exist at: $resolved_path"
    warn "Searching for the actual built driver..."

    local real_so
    real_so="$(find /usr/lib "$HOME" -maxdepth 3 -iname "libvulkan_radeon_driconf.so" 2>/dev/null | head -n1)"

    if [[ -z "$real_so" ]]; then
        err "Could not find libvulkan_radeon_driconf.so anywhere under /usr/lib or $HOME."
        err "The build likely did not complete successfully - check for errors above,"
        err "or in ~/bc250-mesa-build/mesa-*/build/meson-logs/meson-log.txt"
        return 1
    fi

    log "Found the real driver at: $real_so"
    log "Rewriting $json_path to point to it..."
    cp "$json_path" "$json_path.bak.$(date +%s)"
    python3 -c "
import json, sys
path, new_lib = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
data.setdefault('ICD', {})['library_path'] = new_lib
with open(path, 'w') as f:
    json.dump(data, f, indent=4)
" "$json_path" "$real_so"

    if [[ $? -eq 0 ]]; then
        log "Fixed. $json_path now points to $real_so."
        return 0
    else
        err "Failed to rewrite $json_path. You may need to fix library_path manually:"
        err "  \"library_path\": \"$real_so\""
        return 1
    fi
}

if [[ $REBUILD_STATUS -eq 0 ]]; then
    log "Rebuild script finished. Verifying the ICD JSON is set up correctly..."
    if verify_icd_json; then
        log "All good — VK_ICD_FILENAMES should point at this JSON and just work."
    else
        err "ICD JSON verification found a problem (see above). Fix it before"
        err "expecting VK_ICD_FILENAMES to work for any game."
    fi
else
    warn "bc250-rebuild.sh exited with status $REBUILD_STATUS — skipping ICD JSON"
    warn "verification since the build likely didn't finish. Fix the build error"
    warn "above and rerun this prep script."
fi

exit "$REBUILD_STATUS"
