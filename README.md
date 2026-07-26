# BC-250 Mesh Shader Patch - CachyOS Edition

## What is this?

Some newer games (like Final Fantasy VII Rebirth) require a GPU
feature called "mesh shaders" just to start up at all. Without this
patch, those games will show a "DX12 not supported" error and refuse
to launch on a BC-250.

Your BC-250's hardware can actually do mesh shaders - the graphics
driver (Mesa) just doesn't have that feature turned on for this chip
by default. This patch turns it on, only for the specific games you
choose (not your whole system) - so it's safe to install as your
everyday driver.

**Helper scripts included in this repo:**
- `bc250-rebuild.sh` - builds/rebuilds everything automatically
- `bc250-add-game.sh` - easily add a new game to the fix
- `bc250-doctor.sh` - checks your setup and fixes common problems

---

## Before you start

You will need to type commands into a terminal. Copy each command
exactly as written, one at a time, and press Enter after each one.
If a command asks for your password, type it and press Enter (the
password won't show as you type - that's normal, not a bug).

**If your terminal uses `fish` shell** (some distros default to this),
some commands below won't work as-is - fish uses different syntax for
variables. To avoid this entirely, type `bash` first and press Enter
before starting any of the steps below:

```bash
bash
```

You'll know it worked if your prompt changes slightly. Everything
after that will run in bash instead.

This whole process takes 20-40 minutes, mostly waiting for one long
step (the build).

---

## Step 1: Download the files from this repo

Download these two files to the same folder (e.g. your Downloads
folder):
- `bc250_driconf_fix.patch`
- `bc250-rebuild.sh`

## Step 2: Run the build script

```bash
cd ~/Downloads
chmod +x bc250-rebuild.sh
bash bc250-rebuild.sh
```

That's genuinely it - one command. The script will:
1. Install any build tools you're missing
2. Back up your existing driver, if you have one from before
3. Download Mesa's source code
4. Apply the patch
5. Build the driver (the long step - just wait)
6. Install it and double-check everything actually worked before
   finishing

If anything fails partway through, the script will stop and tell you
clearly what went wrong, rather than leaving you with a broken setup.

---

## Step 3: Turn the feature on for your game

By default, the new driver does nothing different for any game - you
have to explicitly tell it which game(s) should get the mesh shader
fix.

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

---

## Step 4: Set the launch option in Steam

Right-click the game in your Steam library, Properties, General, find
the Launch Options box, and paste this exact line (replace `USERNAME`
with your actual username - check by running `whoami` in a terminal):

```
VK_ICD_FILENAMES=/home/USERNAME/radeon_driconf_icd.x86_64.json %command%
```

Launch the game normally from Steam.

---

## Don't want to set a launch option for every game?

You can set the environment variable for your **entire desktop
session** instead, using systemd's user environment system. This
applies it to everything you run - Steam, every game, everything -
without needing a launch option each time:

```bash
mkdir -p ~/.config/environment.d
cat > ~/.config/environment.d/bc250-mesh-shaders.conf << EOF
VK_ICD_FILENAMES=$HOME/radeon_driconf_icd.x86_64.json
EOF
```

**Log out and log back in** (a full session restart, not just closing
Steam) for this to take effect. After that, you can skip Step 4
entirely for any game you set up.

**To undo this later:**
```bash
rm ~/.config/environment.d/bc250-mesh-shaders.conf
```
Then log out and back in again.

---

## How do I know it worked?

Run the diagnostic script:

```bash
chmod +x ~/Downloads/bc250-doctor.sh
bash ~/Downloads/bc250-doctor.sh
```

It checks everything automatically and tells you exactly what's
wrong (if anything), fixing simple problems on its own.

Or check manually:
```bash
VK_ICD_FILENAMES=~/radeon_driconf_icd.x86_64.json vulkaninfo | grep -i "meshShader ="
```
This should show `false` normally, and `true` only when run as a game
you've configured in `~/.drirc`.

---

## Something went wrong - how do I undo this?

Nothing about this process replaces your system's actual default
driver - it's installed alongside as a separate file. To stop using
it:

- Remove the launch option from Steam, or
- Delete everything:
  ```bash
  sudo rm /usr/lib/libvulkan_radeon_driconf.so
  rm ~/radeon_driconf_icd.x86_64.json
  rm ~/.drirc
  ```

Your system goes back to exactly how it was before.

---

## If a system update breaks this later

CachyOS updates packages regularly, and a future Mesa release could
change things enough that this patch stops applying cleanly, or the
driver stops working right.

Just run the same script again - it automatically backs up your
current driver first, rebuilds from scratch, and checks everything
works before finishing:

```bash
bash ~/Downloads/bc250-rebuild.sh
```

To try a specific newer Mesa version:
```bash
bash ~/Downloads/bc250-rebuild.sh mesa-26.3.0
```

If the patch fails to apply after a Mesa update, the script will stop
and tell you rather than installing something broken - please open an
issue on this repo if that happens.

---

## Known issues

- Async compute is unavailable on this chip due to a genuine,
  documented hardware bug (Mesa's own source has a comment noting
  this) - not something this patch can fix.
- Some other DX12 Ultimate features (hardware ray tracing, VRS) are
  untested with this patch and may have their own issues.
- This patch is specific to GFX1013 (BC-250) only - it has no effect
  on any other GPU and is safe to use as a general daily driver.

## Questions or problems?

Open an issue on this GitHub repo with:
- What step you got stuck on
- The exact error message or text you saw
- The output of `bash bc250-doctor.sh`
