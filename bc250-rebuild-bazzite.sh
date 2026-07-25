#!/bin/bash
# bc250-rebuild-bazzite.sh
#
# Builds/rebuilds the BC-250 driconf mesh shader patch on Bazzite
# (or any other immutable/image-based distro). Uses a distrobox
# container for the build toolchain since Bazzite's host system is
# read-only, and installs the driver under $HOME instead of /usr/lib
# since that's also read-only.
#
# Usage: bash bc250-rebuild-bazzite.sh [mesa-tag]

set -e

MESA_TAG="${1:-mesa-26.1.4}"
BUILD_ROOT="$HOME/bc250-mesa-build"
PATCH_FILE="$(dirname "$(readlink -f "$0")")/bc250_driconf_fix.patch"
DRIVER_DIR="$HOME/.local/lib"
DRIVER_OUT="$DRIVER_DIR/libvulkan_radeon_driconf.so"
ICD_OUT="$HOME/radeon_driconf_icd.x86_64.json"
CONTAINER_NAME="bc250-mesa-build"

echo "=== BC-250 Mesh Shader Patch Rebuilder (Bazzite edition) ==="
echo "Target Mesa version: $MESA_TAG"
echo ""

if [ ! -f "$PATCH_FILE" ]; then
    echo "ERROR: Could not find bc250_driconf_fix.patch next to this script."
    echo "Expected at: $PATCH_FILE"
    exit 1
fi

mkdir -p "$DRIVER_DIR"
mkdir -p "$BUILD_ROOT"

# 1. Create the build container if it doesn't already exist
if ! distrobox list 2>/dev/null | grep -q "$CONTAINER_NAME"; then
    echo "[1/7] Creating distrobox build container (first time only)..."
    distrobox create --name "$CONTAINER_NAME" --image archlinux:latest --yes
else
    echo "[1/7] Build container already exists, reusing it."
fi

# 2. Install dependencies inside the container
echo "[2/7] Installing build dependencies inside the container..."
distrobox enter "$CONTAINER_NAME" -- sudo pacman -Sy --needed --noconfirm \
    base-devel git python-mako python-yaml ninja meson vulkan-headers

# 3. Back up the currently installed driver, if any
if [ -f "$DRIVER_OUT" ]; then
    BACKUP_NAME="${DRIVER_OUT}.backup-$(date +%Y%m%d-%H%M%S)"
    echo "[3/7] Backing up existing driver to $BACKUP_NAME"
    cp "$DRIVER_OUT" "$BACKUP_NAME"
else
    echo "[3/7] No existing driver found, skipping backup."
fi

# 4. Fresh clone (this happens on the host filesystem, which distrobox
#    shares with the container - no need to clone from inside it)
echo "[4/7] Cloning Mesa ($MESA_TAG)..."
MESA_DIR="$BUILD_ROOT/mesa-$MESA_TAG"
rm -rf "$MESA_DIR"
distrobox enter "$CONTAINER_NAME" -- git clone --depth 1 --branch "$MESA_TAG" \
    https://gitlab.freedesktop.org/mesa/mesa.git "$MESA_DIR"

# 5. Apply the patch (run inside the container, since Bazzite's host
#    image may not include the `patch` utility at all)
echo "[5/7] Applying BC-250 driconf patch..."
if ! distrobox enter "$CONTAINER_NAME" -- bash -c "cd '$MESA_DIR' && patch -p1 --fuzz=5 -i '$PATCH_FILE'"; then
    echo ""
    echo "!!! PATCH FAILED TO APPLY CLEANLY !!!"
    echo "Check the .rej files in $MESA_DIR. Aborting - not building from"
    echo "a partially-patched tree."
    exit 1
fi

if ! grep -q "spoof_gfx1013_as_gfx10_3" "$MESA_DIR/src/amd/vulkan/radv_physical_device.c"; then
    echo ""
    echo "!!! PATCH APPLIED BUT KEY MARKER NOT FOUND - ABORTING !!!"
    exit 1
fi

# 6. Build, inside the container
echo "[6/7] Building (this can take 10-30+ minutes)..."
distrobox enter "$CONTAINER_NAME" -- bash -c "
    cd '$MESA_DIR'
    meson setup build \
      -Dvulkan-drivers=amd -Dgallium-drivers=zink \
      -Dglx=disabled -Degl=disabled -Dgles2=disabled \
      -Dshared-llvm=disabled -Dllvm=disabled \
      -Dxmlconfig=disabled -Dlmsensors=disabled -Dvalgrind=disabled
    ninja -C build src/amd/vulkan/libvulkan_radeon.so
"

if [ ! -f "$MESA_DIR/build/src/amd/vulkan/libvulkan_radeon.so" ]; then
    echo ""
    echo "!!! BUILD DID NOT PRODUCE A DRIVER FILE - ABORTING !!!"
    exit 1
fi

# 7. Install to $HOME (NOT /usr/lib - that's read-only on Bazzite)
echo "[7/7] Installing driver to $DRIVER_OUT (not /usr/lib - Bazzite's"
echo "system files are read-only, so we keep everything under your home"
echo "folder instead)..."
cp "$MESA_DIR/build/src/amd/vulkan/libvulkan_radeon.so" "$DRIVER_OUT"

cat > "$ICD_OUT" << EOF
{
  "file_format_version": "1.0.0",
  "ICD": {
    "library_path": "$DRIVER_OUT",
    "api_version": "1.4.309"
  }
}
EOF

echo ""
echo "Verifying driver loads correctly..."
if VK_ICD_FILENAMES="$ICD_OUT" vulkaninfo --summary >/dev/null 2>&1; then
    echo ""
    echo "=== Success ==="
    echo "Driver built against $MESA_TAG, installed at: $DRIVER_OUT"
    echo "ICD file: $ICD_OUT"
    echo ""
    echo "Remember: mesh shaders only activate for apps listed in ~/.drirc"
    echo "(use bc250-add-game.sh to add a game)."
else
    echo ""
    echo "!!! WARNING: New driver failed basic vulkaninfo check !!!"
    echo "Do NOT rely on this build. Restore your previous backup if needed:"
    ls "${DRIVER_OUT}".backup-* 2>/dev/null | tail -1
    exit 1
fi
