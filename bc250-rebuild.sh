#!/bin/bash
# bc250-rebuild.sh
#
# Rebuilds the BC-250 driconf-based mesh shader patch against a
# specified Mesa version. Run this after updating Mesa, or to switch
# to a newer Mesa release, to regenerate the modded driver.
#
# Usage: bash bc250-rebuild.sh [mesa-tag]
# Example: bash bc250-rebuild.sh mesa-26.1.4
# If no tag is given, defaults to the last known-working version.

set -e

MESA_TAG="${1:-mesa-26.1.4}"
BUILD_ROOT="$HOME/bc250-mesa-build"
PATCH_FILE="$(dirname "$(readlink -f "$0")")/bc250_driconf_fix.patch"
DRIVER_OUT="/usr/lib/libvulkan_radeon_driconf.so"
ICD_OUT="$HOME/radeon_driconf_icd.x86_64.json"

echo "=== BC-250 Mesh Shader Patch Rebuilder ==="
echo "Target Mesa version: $MESA_TAG"
echo ""

if [ ! -f "$PATCH_FILE" ]; then
    echo "ERROR: Could not find bc250_driconf_fix.patch next to this script."
    echo "Expected at: $PATCH_FILE"
    exit 1
fi

# 1. Dependencies
echo "[1/7] Checking dependencies..."
command -v ninja >/dev/null 2>&1 || sudo pacman -S --needed --noconfirm ninja
python3 -c "import mako" 2>/dev/null || sudo pacman -S --needed --noconfirm python-mako
python3 -c "import yaml" 2>/dev/null || sudo pacman -S --needed --noconfirm python-yaml

# 2. Back up the currently installed driver, if any, before doing anything else
if [ -f "$DRIVER_OUT" ]; then
    BACKUP_NAME="${DRIVER_OUT}.backup-$(date +%Y%m%d-%H%M%S)"
    echo "[2/7] Backing up existing driver to $BACKUP_NAME"
    sudo cp "$DRIVER_OUT" "$BACKUP_NAME"
else
    echo "[2/7] No existing driver found at $DRIVER_OUT, skipping backup."
fi

# 3. Fresh clone of the requested Mesa version
echo "[3/7] Cloning Mesa ($MESA_TAG)..."
MESA_DIR="$BUILD_ROOT/mesa-$MESA_TAG"
rm -rf "$MESA_DIR"
mkdir -p "$BUILD_ROOT"
git clone --depth 1 --branch "$MESA_TAG" https://gitlab.freedesktop.org/mesa/mesa.git "$MESA_DIR"

# 4. Apply the patch, and STOP if anything fails to apply cleanly
echo "[4/7] Applying BC-250 driconf patch..."
cd "$MESA_DIR"
if ! patch -p1 --fuzz=5 -i "$PATCH_FILE"; then
    echo ""
    echo "!!! PATCH FAILED TO APPLY CLEANLY !!!"
    echo "Mesa's source has likely changed in a way this patch doesn't expect."
    echo "Check the .rej files in $MESA_DIR for what didn't apply, and update"
    echo "the patch manually before re-running this script. Aborting - NOT"
    echo "installing a driver built from a partially-patched tree."
    exit 1
fi

# Sanity check: confirm the key marker is actually present, not just that
# patch reported success (patch can sometimes report success with fuzz
# while still landing in the wrong place)
if ! grep -q "spoof_gfx1013_as_gfx10_3" src/amd/vulkan/radv_physical_device.c; then
    echo ""
    echo "!!! PATCH APPLIED BUT KEY MARKER NOT FOUND !!!"
    echo "Something is wrong - aborting before build. Please check manually."
    exit 1
fi

# 5. Build
echo "[5/7] Building (this can take 10-30+ minutes)..."
python3 -m venv venv
venv/bin/pip install --quiet meson
VENV="$MESA_DIR/venv"

PYTHONPATH="$VENV/lib/python3"*/site-packages "$VENV/bin/meson" setup build \
  -Dvulkan-drivers=amd -Dgallium-drivers=zink \
  -Dglx=disabled -Degl=disabled -Dgles2=disabled \
  -Dshared-llvm=disabled -Dllvm=disabled \
  -Dxmlconfig=enabled -Dlmsensors=disabled -Dvalgrind=disabled

PYTHONPATH="$VENV/lib/python3"*/site-packages ninja -C build src/amd/vulkan/libvulkan_radeon.so

# 6. Verify the build actually produced a driver before installing it
if [ ! -f "build/src/amd/vulkan/libvulkan_radeon.so" ]; then
    echo ""
    echo "!!! BUILD DID NOT PRODUCE A DRIVER FILE !!!"
    echo "Aborting - nothing will be installed."
    exit 1
fi

# 7. Install
echo "[6/7] Installing driver..."
sudo cp build/src/amd/vulkan/libvulkan_radeon.so "$DRIVER_OUT"

cat > "$ICD_OUT" << EOF
{
  "file_format_version": "1.0.0",
  "ICD": {
    "library_path": "$DRIVER_OUT",
    "api_version": "1.4.309"
  }
}
EOF

# 8. Quick sanity check that the new driver at least loads
echo "[7/7] Verifying driver loads correctly..."
if VK_ICD_FILENAMES="$ICD_OUT" vulkaninfo --summary >/dev/null 2>&1; then
    echo ""
    echo "=== Success ==="
    echo "Driver rebuilt against $MESA_TAG and installed at: $DRIVER_OUT"
    echo "ICD file: $ICD_OUT"
    echo ""
    echo "Remember: mesh shaders only activate for apps listed in ~/.drirc"
    echo "(see README_driconf.md if you need to add a new game)."
else
    echo ""
    echo "!!! WARNING: New driver failed basic vulkaninfo check !!!"
    echo "Do NOT rely on this build. Restore your previous backup if needed:"
    ls "${DRIVER_OUT}".backup-* 2>/dev/null | tail -1
    exit 1
fi
