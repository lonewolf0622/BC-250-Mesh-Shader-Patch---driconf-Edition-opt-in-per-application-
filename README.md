# BC-250 Mesh Shader Patch - Bazzite Edition

## What is this?

Some newer games (like Final Fantasy VII Rebirth) require a GPU
feature called "mesh shaders" just to start up at all. Without this
patch, those games will show a "DX12 not supported" error and refuse
to launch on a BC-250.

Your BC-250's hardware can actually do mesh shaders - the graphics
driver (Mesa) just doesn't have that feature turned on for this chip
by default. This patch turns it on, only for the specific games you
choose (not your whole system).

**This version is specifically adapted for Bazzite** (or any similar
immutable/image-based Linux system, like SteamOS). Bazzite's system
files can't be modified directly the normal way, so this uses a
different build process than a regular Arch/CachyOS setup.

**Helper scripts included in this repo:**
- `bc250-rebuild-bazzite.sh` - builds/rebuilds everything automatically
- `bc250-add-game.sh` - easily add a new game to the fix (works the
  same on Bazzite as anywhere else, no changes needed for this one)

---

## Before you start

You'll need `distrobox` installed - Bazzite normally already includes
this by default. If you're not sure, run:

```bash
distrobox --version
```

If that shows a version number, you're good to go. If it says
"command not found", check Bazzite's own documentation for how to
install it.

This whole process takes 20-40 minutes, mostly waiting for one long
step (the build). The very first run also needs to download a small
Linux container image, which takes a few extra minutes.

---

## Step 1: Download the files from this repo

Download these two files to the same folder (e.g. your Downloads
folder):
- `bc250_driconf_fix.patch`
- `bc250-rebuild-bazzite.sh`

## Step 2: Run the build script

```bash
cd ~/Downloads
chmod +x bc250-rebuild-bazzite.sh
bash bc250-rebuild-bazzite.sh
```

That's genuinely it - one command. The script will:
1. Create a small build environment (a "distrobox" container) the
   first time you run it - this is a normal, safe, standard way to
   get build tools on Bazzite without modifying the system itself
2. Download Mesa's source code
3. Apply the patch
4. Build the driver (the long step - just wait)
5. Install it to your home folder (not `/usr/lib` - Bazzite keeps
   that read-only on purpose, so everything here lives safely under
   your own account instead)
6. Double-check everything actually worked before finishing

If anything fails partway through, the script will stop and tell you
clearly what went wrong, rather than leaving you with a broken setup.

---

## Step 3: Turn the feature on for your game

By default, the new driver does nothing different for any game -
you have to explicitly tell it which game(s) should get the mesh
shader fix.

Download `bc250-add-game.sh` from this repo too, then:

```bash
chmod +x ~/Downloads/bc250-add-game.sh
bash ~/Downloads/bc250-add-game.sh
```

It'll ask you to launch your game, show you a list of running games
to pick from, and set everything up automatically - no manual file
editing needed.

**To add another game later**, just run the script again - it'll add
the new game alongside any you've already configured, without
removing them.

**If the script doesn't find your game in the list**, make sure the
game is actually running (or has at least tried to launch) at the
moment you press Enter in the script. Some games take a few seconds
to start their actual process after you click Play in Steam.

---

## Step 4: Set the launch option in Steam

Right-click the game in your Steam library, Properties, General, find
the Launch Options box.

**The build script tells you exactly what to paste here at the end of
Step 3** - copy that line exactly. It'll be one of these two forms,
depending on your system:

```
VK_ICD_FILENAMES=/home/USERNAME/radeon_driconf_icd.x86_64.json %command%
```

or, if some runtime libraries weren't already on your system:

```
LD_LIBRARY_PATH=/home/USERNAME/.local/lib/bc250-runtime-libs VK_ICD_FILENAMES=/home/USERNAME/radeon_driconf_icd.x86_64.json %command%
```

(replace `USERNAME` with your actual username - check by running
`whoami` in a terminal)

Launch the game normally from Steam.

---

## Don't want to set a launch option for every game?

On a regular Linux system you'd normally do this by replacing the
system driver file directly - but Bazzite keeps `/usr/lib` permanently
read-only by design, so that approach doesn't work here.

Instead, you can set the environment variable for your **entire
desktop session** instead of per-game, using systemd's user
environment system. This applies it to everything you run - Steam,
every game, everything - without touching any system file:

```bash
mkdir -p ~/.config/environment.d
cat > ~/.config/environment.d/bc250-mesh-shaders.conf << EOF
VK_ICD_FILENAMES=$HOME/radeon_driconf_icd.x86_64.json
EOF
```

**Log out and log back in** (a full session restart, not just closing
Steam) for this to take effect. After that, you can skip Step 4
entirely - no launch option needed for any game.

Since the driconf patch only activates for games listed in
`~/.drirc` anyway, this is just as safe as the launch-option approach
- it doesn't force the spoof on for everything, it just makes the
*driver itself* available everywhere, while `~/.drirc` still controls
which games actually use the feature.

**To undo this later:**
```bash
rm ~/.config/environment.d/bc250-mesh-shaders.conf
```
Then log out and back in again.

---

## How do I know it worked?

```bash
VK_ICD_FILENAMES=~/radeon_driconf_icd.x86_64.json vulkaninfo | grep -i "meshShader ="
```

You should see `meshShader = true`.

---

## Already installed this before? Here's how to fix it cleanly

An earlier version of this guide had a critical bug: the build was
missing one setting (`xmlconfig=enabled`) that's required for the
`.drirc` game-switching feature to actually work at all. If you set
this up before and mesh shaders never seemed to turn on no matter
what you tried, this was almost certainly why.

**Good news: your existing setup isn't broken or dangerous, it just
needs a clean rebuild.** Do this to fix it properly rather than
patching over the old one:

```bash
# Remove the old build container and build folder entirely
distrobox rm bc250-mesa-build -f
rm -rf ~/bc250-mesa-build

# Remove the old driver files (safe - nothing else depends on these)
rm -f ~/.local/lib/libvulkan_radeon_driconf.so
rm -rf ~/.local/lib/bc250-runtime-libs
rm -f ~/radeon_driconf_icd.x86_64.json
```

Your `~/.drirc` file (if you already set one up) is fine and doesn't
need to change - it was always correct, it just wasn't being read.
Leave it as-is.

Then just start fresh from **Step 1** of this guide (download the
latest files, run the build script again). Make sure you're using the
newest version of `bc250-rebuild-bazzite.sh` from this repo, not an
older downloaded copy - check your Downloads folder for duplicates
and delete any old ones first:

```bash
rm -f ~/Downloads/bc250-rebuild-bazzite.sh
```

Then download it fresh from this repo before re-running.

---

## Something went wrong - how do I undo this?

Nothing about this process touches Bazzite's actual system files -
everything lives in your home folder and inside the distrobox
container. To stop using the patched driver:

- Remove the launch option from Steam, or
- Delete everything:
  ```bash
  rm ~/.local/lib/libvulkan_radeon_driconf.so
  rm ~/radeon_driconf_icd.x86_64.json
  rm ~/.drirc
  distrobox rm bc250-mesa-build
  ```

Your system goes back to exactly how it was before.

---

## Game shows a fatal error / crashes on launch even after setup

**Run the diagnostic script first** - it checks every piece of the
setup automatically and fixes what it can:

```bash
chmod +x ~/Downloads/bc250-doctor.sh
bash ~/Downloads/bc250-doctor.sh
```

It'll tell you exactly what's wrong (if anything) and fix simple
problems automatically. If everything passes but the game still
doesn't work, it'll show you exactly what to include when asking for
help.

---

## If a Mesa update breaks this later

Just run the same script again - it automatically backs up your
current driver first, rebuilds from scratch, and checks everything
works before finishing:

```bash
bash ~/Downloads/bc250-rebuild-bazzite.sh
```

To try a specific newer Mesa version:

```bash
bash ~/Downloads/bc250-rebuild-bazzite.sh mesa-26.3.0
```

---

## Known issues

- Async compute (a GPU performance feature) doesn't work on this chip
  at all - this is a real hardware limitation, not something this
  patch causes or can fix.
- This has only been thoroughly tested with Final Fantasy VII
  Rebirth on CachyOS. The Bazzite build process itself (distrobox,
  home-folder installation) is a newer adaptation and may need some
  troubleshooting on your specific setup.

## Questions or problems?

Open an issue on this GitHub repo with:
- What step you got stuck on
- The exact error message or text you saw
- The output of `vulkaninfo | grep -i "deviceName"`
