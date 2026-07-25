#!/bin/bash
# bc250-add-game.sh
#
# Adds a new game to ~/.drirc so it gets the BC-250 mesh shader
# spoof enabled. Handles finding the real executable name and safely
# editing the XML config, so you don't have to do it by hand.
#
# Usage: bash bc250-add-game.sh
# (just run it and follow the prompts)

set -e

DRIRC="$HOME/.drirc"

echo "=== BC-250: Add a game to the mesh shader fix ==="
echo ""
echo "Step 1: Launch the game now (through Steam, as normal)."
echo "It's OK if it fails to start or crashes - we just need it"
echo "running for a moment so we can find its real process name."
echo ""
read -p "Press Enter once the game is running (or has tried to launch)... "

echo ""
echo "Searching for running game processes..."
echo ""

# Show all recently-started processes that look game-like (heuristic:
# anything with .exe in the name, since these are all Proton/Wine games)
mapfile -t candidates < <(ps -eo comm | grep -i '\.exe$' | sort -u)

if [ ${#candidates[@]} -eq 0 ]; then
    echo "No .exe processes found running right now."
    echo "Make sure the game is actually launched (or was launched in the"
    echo "last few seconds) and try again."
    exit 1
fi

echo "Found these running .exe processes:"
echo ""
for i in "${!candidates[@]}"; do
    echo "  $((i+1))) ${candidates[$i]}"
done
echo ""
read -p "Which number is your game? " choice

selected="${candidates[$((choice-1))]}"

if [ -z "$selected" ]; then
    echo "Invalid selection. Run the script again."
    exit 1
fi

echo ""
echo "Selected executable name: $selected"
echo ""
read -p "Enter a friendly name for this game (e.g. 'FF7 Rebirth'): " friendly_name

# Build the new application block
NEW_BLOCK="        <application name=\"${friendly_name}\" executable=\"${selected}\">
            <option name=\"radv_spoof_gfx1013_as_gfx10_3\" value=\"true\" />
        </application>"

if [ ! -f "$DRIRC" ]; then
    echo ""
    echo "No existing ~/.drirc found - creating a new one."
    cat > "$DRIRC" << EOF
<driconf>
    <device>
$NEW_BLOCK
    </device>
</driconf>
EOF
else
    # Check if this executable is already configured
    if grep -q "executable=\"${selected}\"" "$DRIRC"; then
        echo ""
        echo "This game (${selected}) is already in your ~/.drirc - nothing to do."
        exit 0
    fi

    echo ""
    echo "Adding to your existing ~/.drirc..."
    # Insert the new block just before the closing </device> tag
    python3 << PYEOF
import re

with open("$DRIRC") as f:
    content = f.read()

new_block = '''$NEW_BLOCK'''

if "</device>" in content:
    content = content.replace("</device>", new_block + "\n    </device>", 1)
else:
    print("Could not find </device> tag in ~/.drirc - please add this manually:")
    print(new_block)
    exit(1)

with open("$DRIRC", "w") as f:
    f.write(content)
PYEOF
fi

echo ""
echo "=== Done ==="
echo "Added '$friendly_name' ($selected) to ~/.drirc"
echo ""
echo "Now add this to the game's Steam launch options if you haven't already:"
echo "  VK_ICD_FILENAMES=$HOME/radeon_driconf_icd.x86_64.json %command%"
echo ""
echo "Current ~/.drirc contents:"
echo "---"
cat "$DRIRC"
