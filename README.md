# BC-250 Mesh Shader Patch — SteamOS Edition

This is a SteamOS-specific wrapper for [lonewolf0622's BC-250 Mesh Shader Patch](https://github.com/lonewolf0622/BC-250-Mesh-Shader-Patch---driconf-Edition-opt-in-per-application-) (driconf edition). The original guide targets CachyOS/Bazzite, which ship a full Arch dev toolchain out of the box. SteamOS's base image strips out several dev headers and `pkg-config` files that Mesa's build needs — this wrapper detects and works around those gaps automatically.

**What this patch does:** turns on mesh shader support in Mesa's RADV Vulkan driver for the BC-250's GPU (GFX1013), scoped only to games you explicitly opt in — not a system-wide driver replacement. Some newer titles (like Final Fantasy VII Rebirth) need mesh shaders just to launch at all.

---

## Before you start

You'll need a terminal. If you're on Desktop Mode, open **Konsole** (or your preferred terminal).

If your terminal defaults to `fish` shell, type `bash` and press Enter first — the commands below assume bash syntax.

This whole process takes 20–40 minutes, mostly spent waiting on the Mesa build itself.

---

## Step 1: Download the files

You need **five files total, all sitting in the same folder** (e.g. `~/Downloads`). Four come from GitHub, and **one you already have from this chat and must save yourself** — it's not on GitHub, since it was custom-built for you here.

| # | File | Where it comes from |
|---|------|---------------------|
| 1 | `bc250-rebuild.sh` | GitHub (commands below) |
| 2 | `bc250-add-game.sh` | GitHub (commands below) |
| 3 | `bc250-doctor.sh` | GitHub (commands below) |
| 4 | `bc250_driconf_fix.patch` | GitHub (commands below) |
| 5 | **`bc250-steamos-prep.sh`** | **Download it from the chat message where it was shared — click the file, save it, and make sure it ends up in `~/Downloads` next to the other four.** |

> ⚠️ **Easy mistake to make:** if `bc250-steamos-prep.sh` isn't in the same folder as the other four when you run it, it fails immediately with "Could not find bc250-rebuild.sh." That's intentional — it fails loudly instead of guessing or doing something wrong silently. If you see that error, check `ls ~/Downloads` and confirm all five files are actually there.

Run these to grab the first four (pulled from the repo's **`Steam-OS`** branch):

```bash
mkdir -p ~/Downloads && cd ~/Downloads
curl -LO https://raw.githubusercontent.com/lonewolf0622/BC-250-Mesh-Shader-Patch---driconf-Edition-opt-in-per-application-/Steam-OS/bc250-rebuild.sh
curl -LO https://raw.githubusercontent.com/lonewolf0622/BC-250-Mesh-Shader-Patch---driconf-Edition-opt-in-per-application-/Steam-OS/bc250-add-game.sh
curl -LO https://raw.githubusercontent.com/lonewolf0622/BC-250-Mesh-Shader-Patch---driconf-Edition-opt-in-per-application-/Steam-OS/bc250-doctor.sh
curl -LO https://raw.githubusercontent.com/lonewolf0622/BC-250-Mesh-Shader-Patch---driconf-Edition-opt-in-per-application-/Steam-OS/bc250_driconf_fix.patch
```

> If any of these come back as a tiny file containing `404: Not Found` instead of the real script, check the exact file names on that branch at:
> https://github.com/lonewolf0622/BC-250-Mesh-Shader-Patch---driconf-Edition-opt-in-per-application-/tree/Steam-OS
> and adjust the filename in the URL above to match — branch contents can differ slightly from `main`.

(Copy `bc250-steamos-prep.sh` into the same folder from wherever you saved it.)

## Step 2: Double-check you have all five files

Before running anything, confirm everything landed in the right place:

```bash
cd ~/Downloads
ls bc250-rebuild.sh bc250-add-game.sh bc250-doctor.sh bc250_driconf_fix.patch bc250-steamos-prep.sh
```

You should see all five filenames printed back with no "No such file or directory" errors. If one is missing, go back and grab it before continuing — running the prep script without all five in place will just stop early with a clear error, but it's faster to check now.

## Step 3: Run the SteamOS prep + build

```bash
chmod +x bc250-steamos-prep.sh
./bc250-steamos-prep.sh
```

This single command will, in order:

1. Disable SteamOS's read-only root (needed to install packages)
2. Initialize pacman's keyring if it hasn't been already
3. Check for `libelf`, `zlib`, and `libzstd` dev headers — SteamOS ships these as runtime-only, so if pacman can't provide the dev files, the script pulls them straight from the official Arch mirror
4. Install the rest of the build dependencies (Wayland, X11/xcb, libffi, etc.)
5. Point Meson's temp directory away from `/tmp` (SteamOS mounts it `noexec`, which causes cryptic Meson configure failures otherwise)
6. Hand off to `bc250-rebuild.sh` to actually clone, patch, and build Mesa

It's safe to rerun if something fails partway — just fix whatever it reported and run it again.

## Step 4: Register your game

```bash
chmod +x bc250-add-game.sh
bash bc250-add-game.sh
```

Launch the game through Steam when prompted, then pick it from the list.

## Step 5: Set the Steam launch option

Right-click the game in Steam → **Properties** → **General** → **Launch Options**:

```
VK_ICD_FILENAMES=/home/deck/radeon_driconf_icd.x86_64.json %command%
```

Replace `deck` with your actual username if different (check with `whoami`).

## Step 6: Verify

```bash
chmod +x bc250-doctor.sh
bash bc250-doctor.sh
```

---

## Setting environment variables permanently (skip per-game launch options)

Instead of setting `VK_ICD_FILENAMES` as a launch option for every single game, you can set it once for your whole desktop session using systemd's user environment system. Once set, it applies automatically to everything — Steam, all your games — with no launch option needed.

### One-time setup

```bash
mkdir -p ~/.config/environment.d
cat > ~/.config/environment.d/bc250-mesh-shaders.conf << 'EOF'
VK_ICD_FILENAMES=/home/deck/radeon_driconf_icd.x86_64.json
EOF
```

Replace `deck` with your username if different.

**Log out and log back in** — a full session restart, not just closing/reopening Steam — for this to take effect. Desktop Mode → Log Out → Log back in.

Check it's active by opening a fresh terminal:

```bash
echo $VK_ICD_FILENAMES
```

If that prints your JSON path, you're set — you can skip Step 5 above for any future game.

### If you also want TMPDIR to persist (only needed if you rebuild the driver often)

The prep script sets `TMPDIR` for its own session automatically, so you don't need this for normal use. But if you're doing a lot of manual Mesa rebuilding and want it to persist across terminal sessions too:

```bash
cat > ~/.config/environment.d/bc250-build-tmpdir.conf << 'EOF'
TMPDIR=/home/deck/mesa-tmp
EOF
```

Again, log out and back in for it to apply.

### Undoing it

To remove the persistent Vulkan ICD override:

```bash
rm ~/.config/environment.d/bc250-mesh-shaders.conf
```

Log out and back in. Your system reverts to using the default Vulkan driver for everything, exactly as before.

---

## After a SteamOS update

If a SteamOS system update resets your read-only root or a Mesa version bump breaks the patch, just rerun the prep script — it re-checks everything and rebuilds from scratch:

```bash
cd ~/Downloads
./bc250-steamos-prep.sh
```

To try a specific newer Mesa version:

```bash
./bc250-steamos-prep.sh mesa-26.3.0
```

---

## Known issues

- Async compute is unavailable on the BC-250 due to a documented hardware bug in Mesa — not something this patch fixes.
- Hardware ray tracing and VRS are untested with this patch.
- This patch is specific to GFX1013 (BC-250) hardware only.

## Troubleshooting

If the prep script fails on a dependency not already handled, it'll print a clear error naming the missing package or pkg-config module. Install it and rerun — the script is idempotent and safe to run repeatedly. If something look genuinely stuck, check `~/bc250-mesa-build/mesa-*/build/meson-logs/meson-log.txt` for the detailed compiler output behind whatever summary error you're seeing.
