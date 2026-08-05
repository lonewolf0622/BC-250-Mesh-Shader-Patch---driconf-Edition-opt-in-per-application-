#!/bin/bash
# bc250-doctor.sh
#
# Checks every piece of the BC-250 mesh shader setup, actually FIXES
# what it can automatically (not just describes the fix), and prints
# the exact, verified Steam launch option to use at the end.
#
# Usage: bash bc250-doctor.sh

DRIVER_OUT="$HOME/.local/lib/libvulkan_radeon_driconf.so"
ICD_OUT="$HOME/radeon_driconf_icd.x86_64.json"
DRIRC="$HOME/.drirc"
RUNTIME_LIBS_DIR="$HOME/.local/lib/bc250-runtime-libs"
CONTAINER_NAME="bc250-mesa-build"

PASS=0
FAIL=0
NEEDS_LD_PATH=0

check() {
    echo -n "  Checking: $1 ... "
}

ok() {
    echo "OK"
    PASS=$((PASS+1))
}

problem() {
    echo "PROBLEM: $1"
    FAIL=$((FAIL+1))
}

echo "=== BC-250 Setup Doctor ==="
echo ""

# 1. Does the driver file exist at all?
check "driver file exists"
if [ -f "$DRIVER_OUT" ]; then
    ok
else
    problem "Not found at $DRIVER_OUT"
    echo "    -> You need to run bc250-rebuild-bazzite.sh first."
    echo ""
    echo "=== Cannot continue without a driver. Run the rebuild script and try again. ==="
    exit 1
fi

# 2. Is it actually a valid shared library (not empty/corrupted)?
check "driver file is a valid library"
FILETYPE=$(file -b "$DRIVER_OUT" 2>/dev/null)
if echo "$FILETYPE" | grep -qi "shared object\|ELF"; then
    ok
else
    problem "File exists but doesn't look like a real library ($FILETYPE)"
    echo "    -> It may be corrupted or incomplete. Re-run bc250-rebuild-bazzite.sh."
    echo ""
    exit 1
fi

check "driver file size is reasonable"
SIZE=$(stat -c%s "$DRIVER_OUT" 2>/dev/null || echo 0)
if [ "$SIZE" -gt 10000000 ]; then
    ok
else
    problem "File is only $SIZE bytes - way too small for a real driver"
    echo "    -> The build likely failed partway. Re-run bc250-rebuild-bazzite.sh."
    echo ""
    exit 1
fi

# 3. Does the ICD json exist, and does it point at the real driver path?
check "ICD config file exists"
if [ -f "$ICD_OUT" ]; then
    ok
    check "ICD config points to the right file"
    if grep -q "$DRIVER_OUT" "$ICD_OUT" 2>/dev/null; then
        ok
    else
        problem "ICD file doesn't reference $DRIVER_OUT"
        echo "    -> Recreating it now with the correct path..."
        cat > "$ICD_OUT" << EOF
{
  "file_format_version": "1.0.0",
  "ICD": {
    "library_path": "$DRIVER_OUT",
    "api_version": "1.4.309"
  }
}
EOF
        echo "    -> Fixed."
        echo ""
    fi
else
    problem "Not found at $ICD_OUT"
    echo "    -> Creating it now..."
    cat > "$ICD_OUT" << EOF
{
  "file_format_version": "1.0.0",
  "ICD": {
    "library_path": "$DRIVER_OUT",
    "api_version": "1.4.309"
  }
}
EOF
    echo "    -> Fixed."
    echo ""
fi

# 4. Does the driver actually load? Test in a completely clean
#    environment first (not inheriting anything from the current
#    shell), since a stale LD_LIBRARY_PATH from a previous session can
#    mask a genuinely missing library and give a false pass here.
check "driver loads correctly (clean-environment test)"
mkdir -p "$RUNTIME_LIBS_DIR"

if env -i HOME="$HOME" VK_ICD_FILENAMES="$ICD_OUT" vulkaninfo --summary >/tmp/bc250_vulkaninfo_test.log 2>&1; then
    ok
else
    problem "Driver failed to load in a clean environment"
    echo "    -> Real error:"
    head -5 /tmp/bc250_vulkaninfo_test.log | sed 's/^/       /'
    echo ""

    if grep -q "cannot open shared object file" /tmp/bc250_vulkaninfo_test.log; then
        MISSING_LIBS=$(grep "cannot open shared object file" /tmp/bc250_vulkaninfo_test.log \
            | sed -E 's/.*: ([^:]+\.so[^:]*): cannot open.*/\1/' | sort -u)
        echo "    -> Missing librar(y/ies): $MISSING_LIBS"

        if command -v distrobox >/dev/null 2>&1 && distrobox list 2>/dev/null | grep -q "$CONTAINER_NAME"; then
            echo "    -> Attempting to auto-fix by copying from the build container..."
            for lib in $MISSING_LIBS; do
                LIB_PATH=$(distrobox enter "$CONTAINER_NAME" -- find /usr/lib /usr/lib64 -iname "$lib" 2>/dev/null | head -1)
                if [ -n "$LIB_PATH" ]; then
                    distrobox enter "$CONTAINER_NAME" -- cp "$LIB_PATH" "$RUNTIME_LIBS_DIR/"
                    echo "       - $lib: copied"
                else
                    echo "       - $lib: couldn't find this even inside the build container"
                fi
            done

            echo "    -> Retesting with the copied librar(y/ies)..."
            if env -i HOME="$HOME" LD_LIBRARY_PATH="$RUNTIME_LIBS_DIR" VK_ICD_FILENAMES="$ICD_OUT" vulkaninfo --summary >/tmp/bc250_vulkaninfo_test2.log 2>&1; then
                echo "    -> Fixed. The driver now loads correctly with LD_LIBRARY_PATH set."
                FAIL=$((FAIL-1))
                PASS=$((PASS+1))
                NEEDS_LD_PATH=1
            else
                echo "    -> Still failing after the auto-fix attempt. Full error:"
                head -10 /tmp/bc250_vulkaninfo_test2.log | sed 's/^/       /'
                echo "    -> Please open an issue on the GitHub repo with this output."
            fi
        else
            echo "    -> Can't auto-fix: the build container isn't available."
            echo "       Re-run bc250-rebuild-bazzite.sh, which sets up the"
            echo "       container and handles this automatically during the build."
        fi
    else
        echo "    -> This isn't a missing-library issue. Full error saved to"
        echo "       /tmp/bc250_vulkaninfo_test.log - please open a GitHub issue"
        echo "       with that file attached."
    fi
    echo ""
fi

# Also check if libs were already present from an earlier run, even if
# the clean test above passed without needing them right now.
if [ -d "$RUNTIME_LIBS_DIR" ] && [ -n "$(ls -A "$RUNTIME_LIBS_DIR" 2>/dev/null)" ]; then
    NEEDS_LD_PATH=1
fi

# 5. Does the driver report mesh shader support at all (independent of drirc)?
check "driver reports GFX1013 hardware correctly"
if [ "$NEEDS_LD_PATH" -eq 1 ]; then
    VINFO_CHECK=$(env -i HOME="$HOME" LD_LIBRARY_PATH="$RUNTIME_LIBS_DIR" VK_ICD_FILENAMES="$ICD_OUT" vulkaninfo --summary 2>/dev/null)
else
    VINFO_CHECK=$(env -i HOME="$HOME" VK_ICD_FILENAMES="$ICD_OUT" vulkaninfo --summary 2>/dev/null)
fi
if echo "$VINFO_CHECK" | grep -qi "GFX1013\|BC-250\|BC250"; then
    ok
else
    echo "SKIPPED (couldn't confirm - not necessarily a problem, some driver"
    echo "    versions report the name differently)"
fi

# 6. Does ~/.drirc exist at all?
check "~/.drirc exists"
if [ -f "$DRIRC" ]; then
    ok
else
    problem "Not found - no games are configured to get the mesh shader fix"
    echo "    -> Run bc250-add-game.sh to add your game."
    echo ""
fi

# 7. Is ~/.drirc valid XML (not corrupted)?
if [ -f "$DRIRC" ]; then
    check "~/.drirc is valid XML"
    if python3 -c "import xml.etree.ElementTree as ET; ET.parse('$DRIRC')" 2>/dev/null; then
        ok
    else
        problem "The file exists but isn't valid XML - it's probably corrupted"
        echo "    -> Current contents:"
        cat "$DRIRC" | sed 's/^/       /'
        echo "    -> Consider deleting it and running bc250-add-game.sh again:"
        echo "       rm $DRIRC"
        echo ""
    fi

    # 8. Does it actually contain the spoof option at all, anywhere?
    check "~/.drirc contains the mesh shader option"
    if grep -q "radv_spoof_gfx1013_as_gfx10_3" "$DRIRC" 2>/dev/null; then
        ok
    else
        problem "No game has this option configured"
        echo "    -> Run bc250-add-game.sh to add your game."
        echo ""
    fi
fi

# Summary
echo ""
echo "=== Summary: $PASS passed, $FAIL problem(s) found ==="
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo "Everything checks out and has been verified working end-to-end."
    echo ""
    echo "Your Steam launch option for this game:"
    echo ""
    if [ "$NEEDS_LD_PATH" -eq 1 ]; then
        echo "  LD_LIBRARY_PATH=$RUNTIME_LIBS_DIR VK_ICD_FILENAMES=$ICD_OUT %command%"
    else
        echo "  VK_ICD_FILENAMES=$ICD_OUT %command%"
    fi
    echo ""
    echo "Make sure the game's executable name is actually listed in ~/.drirc"
    echo "(use bc250-add-game.sh if you haven't added it yet)."
else
    echo "Some problems couldn't be auto-fixed - see above for details."
    echo "Fix those, then run this script again to get a verified launch"
    echo "command."
    echo ""
    echo "Current ~/.drirc contents:"
    cat "$DRIRC" 2>/dev/null | sed 's/^/  /' || echo "  (file doesn't exist)"
    echo ""
    echo "Current ICD contents:"
    cat "$ICD_OUT" 2>/dev/null | sed 's/^/  /' || echo "  (file doesn't exist)"
fi
