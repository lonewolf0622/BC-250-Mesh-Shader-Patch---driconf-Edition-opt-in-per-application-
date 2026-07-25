#!/bin/bash
# bc250-doctor.sh
#
# Checks every piece of the BC-250 mesh shader setup and fixes what
# it can automatically. Run this if the game shows a fatal error or
# doesn't seem to be picking up the fix, before troubleshooting
# manually.
#
# Usage: bash bc250-doctor.sh

DRIVER_OUT="$HOME/.local/lib/libvulkan_radeon_driconf.so"
ICD_OUT="$HOME/radeon_driconf_icd.x86_64.json"
DRIRC="$HOME/.drirc"

PASS=0
FAIL=0

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
fi

# 2. Is it actually a valid shared library (not empty/corrupted)?
if [ -f "$DRIVER_OUT" ]; then
    check "driver file is a valid library"
    FILETYPE=$(file -b "$DRIVER_OUT" 2>/dev/null)
    if echo "$FILETYPE" | grep -qi "shared object\|ELF"; then
        ok
    else
        problem "File exists but doesn't look like a real library ($FILETYPE)"
        echo "    -> It may be corrupted or incomplete. Re-run bc250-rebuild-bazzite.sh."
        echo ""
    fi

    check "driver file size is reasonable"
    SIZE=$(stat -c%s "$DRIVER_OUT" 2>/dev/null || echo 0)
    if [ "$SIZE" -gt 10000000 ]; then
        ok
    else
        problem "File is only $SIZE bytes - way too small for a real driver"
        echo "    -> The build likely failed partway. Re-run bc250-rebuild-bazzite.sh."
        echo ""
    fi
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

# 4. Does the driver actually load and respond to Vulkan queries?
check "driver loads correctly (vulkaninfo test)"
if VK_ICD_FILENAMES="$ICD_OUT" vulkaninfo --summary >/tmp/bc250_vulkaninfo_test.log 2>&1; then
    ok
else
    problem "vulkaninfo failed to run with this driver"
    echo "    -> Full error saved to /tmp/bc250_vulkaninfo_test.log"
    echo "    -> First few lines of the error:"
    head -10 /tmp/bc250_vulkaninfo_test.log | sed 's/^/       /'
    echo ""
fi

# 5. Does the driver report mesh shader support at all (independent of drirc)?
check "driver reports GFX1013 hardware correctly"
if VK_ICD_FILENAMES="$ICD_OUT" vulkaninfo --summary 2>/dev/null | grep -qi "GFX1013\|BC-250\|BC250"; then
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
    echo "Everything checks out. If the game still isn't working, the issue"
    echo "is likely something else - check the exact error message and open"
    echo "an issue on the GitHub repo with these details:"
    echo ""
    echo "  Current ~/.drirc contents:"
    cat "$DRIRC" 2>/dev/null | sed 's/^/    /' || echo "    (file doesn't exist)"
    echo ""
    echo "  Current ICD contents:"
    cat "$ICD_OUT" 2>/dev/null | sed 's/^/    /' || echo "    (file doesn't exist)"
else
    echo "Fix the problem(s) marked above (some were auto-fixed already),"
    echo "then run this script again to confirm everything passes before"
    echo "trying to launch the game again."
fi
