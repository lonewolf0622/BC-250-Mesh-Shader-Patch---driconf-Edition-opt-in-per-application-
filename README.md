# BC-250 Mesh Shader Patch (driconf version)

## What is this?

Some newer games (like Final Fantasy VII Rebirth) require a GPU
feature called "mesh shaders" just to start up at all. Without this
patch, those games will show a "DX12 not supported" error and refuse
to launch on a BC-250.

Your BC-250's hardware can actually do mesh shaders - the graphics
driver (Mesa) just doesn't have that feature turned on for this chip
by default. This patch turns it on.

**This version only turns the feature on for specific games you
choose** (like FF7 Rebirth), not for your whole system. That makes it
safe to install as your everyday driver.

**Helper scripts included in this repo:**
- `bc250-add-game.sh` - easily add a new game to the fix (see Step 6)
- `bc250-rebuild.sh` - rebuild everything automatically after a Mesa
  update breaks things (see "If a system update breaks this later" at
  the bottom)

---

## Before you start

You will need to type commands into a terminal. Copy each command
exactly as written, one at a time, and press Enter after each one.
If a command asks for your password, type it and press Enter (the
password won't show as you type - that's normal, not a bug).

**If your terminal uses `fish` shell** (CachyOS and some other distros
default to this), some of the commands below won't work as-is - fish
uses different syntax for variables. To avoid this entirely, type
`bash` first and press Enter before starting any of the steps below:

```bash
bash
```

You'll know it worked if your prompt changes slightly. Everything
after that will run in bash instead, and every command in this guide
will work exactly as written. (If you're not sure which shell you
have, just run `bash` anyway - it's harmless even if you didn't need
it.)

This whole process takes 20-40 minutes, mostly waiting for one long
step (the build).

---

## Step 1: Install the tools needed to build this

```bash
sudo pacman -S --needed git python-mako python-yaml ninja base-devel
```

---

## Step 2: Download Mesa's source code

```bash
mkdir -p ~/bc250-mesa-build && cd ~/bc250-mesa-build
git clone --depth 1 --branch mesa-26.1.4 https://gitlab.freedesktop.org/mesa/mesa.git mesa
cd mesa
```

## Step 3: Apply the patch

Download `bc250_driconf_fix.patch` from this repo first, then:

```bash
patch -p1 --fuzz=5 -i ~/Downloads/bc250_driconf_fix.patch
```

**What you should see:** three lines saying `patching file ...`
with no errors. If you see the word `FAILED` anywhere, stop here and
ask for help in the community Discord/GitHub issues - don't continue
to the next step.

## Step 4: Build it

This is the long step. Just let it run.

```bash
python3 -m venv venv
venv/bin/pip install meson
```

```bash
VENV="$HOME/bc250-mesa-build/mesa/venv"
PYTHONPATH="$VENV/lib/python3"*/site-packages "$VENV/bin/meson" setup build \
  -Dvulkan-drivers=amd -Dgallium-drivers=zink \
  -Dglx=disabled -Degl=disabled -Dgles2=disabled \
  -Dshared-llvm=disabled -Dllvm=disabled \
  -Dxmlconfig=disabled -Dlmsensors=disabled -Dvalgrind=disabled
```

```bash
PYTHONPATH="$VENV/lib/python3"*/site-packages ninja -C build src/amd/vulkan/libvulkan_radeon.so
```

This can take 10-30 minutes depending on your hardware. It's normal
for there to be no visible progress for stretches of time - just
wait for it to finish and return you to the command prompt.

---

## Step 5: Install the driver

This copies the new driver next to your existing one, **without
replacing anything** - your system's original driver stays exactly
as it was, completely unaffected.

```bash
sudo cp build/src/amd/vulkan/libvulkan_radeon.so /usr/lib/libvulkan_radeon_driconf.so
```

Create a small config file that tells Steam where to find the new
driver:

```bash
cat > ~/radeon_driconf_icd.x86_64.json << 'EOF'
{
  "file_format_version": "1.0.0",
  "ICD": {
    "library_path": "/usr/lib/libvulkan_radeon_driconf.so",
    "api_version": "1.4.309"
  }
}
EOF
```

---

## Step 6: Turn the feature on for your specific game

By default, the new driver does nothing different for any game -
you have to explicitly tell it which game(s) should get the mesh
shader fix.

**Easiest way - use the helper script:**

Download `bc250-add-game.sh` from this repo, then:

```bash
chmod +x ~/Downloads/bc250-add-game.sh
bash ~/Downloads/bc250-add-game.sh
```

It'll ask you to launch your game, show you a list of running games
to pick from, and set everything up automatically - no manual file
editing needed. Run it again any time you want to add another game.

**Manual way (if you prefer, or the script doesn't work for you):**

Create a file called `.drirc` in your home folder:

```bash
cat > ~/.drirc << 'EOF'
<driconf>
    <device>
        <application name="FF7 Rebirth" executable="ff7rebirth_.exe">
            <option name="radv_spoof_gfx1013_as_gfx10_3" value="true" />
        </application>
    </device>
</driconf>
EOF
```

If you're setting this up for a different game, you need that
game's exact executable name. Launch the game once (it's OK if it
fails to start), then in a terminal run:

```bash
for pid in $(pgrep -i "keyword_from_game_name"); do
  echo "PID $pid: $(cat /proc/$pid/comm)"
done
```

Replace `keyword_from_game_name` with something like `ff7` or part of
the game's name. Whatever name it prints is what goes in the
`executable="..."` part above. Note: this is sometimes slightly
different from the actual file name (for FF7 Rebirth it has an extra
underscore: `ff7rebirth_.exe`, not `ff7rebirth.exe`).

To add a second game later, just run the script again, or add another
`<application>...</application>` block inside the same `<device>`
section if editing manually.

---

## Step 7: Set the launch option in Steam

Right-click the game in your Steam library → **Properties** →
**General** → find the **Launch Options** box, and paste this exact
line (replace `deck` with your actual username if it's different -
check by running `whoami` in a terminal):

```
VK_ICD_FILENAMES=/home/deck/radeon_driconf_icd.x86_64.json %command%
```

That's it. Launch the game normally from Steam.

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
Steam) for this to take effect. After that, you can skip Step 7
entirely for any game you set up.

Since the driconf patch only activates for games listed in `~/.drirc`
anyway, this is just as safe as the launch-option approach - it
doesn't force the spoof on for everything, it just makes the *driver
itself* available everywhere, while `~/.drirc` still controls which
games actually use the feature. This also avoids touching your
system's actual driver file at all, unlike replacing
`/usr/lib/libvulkan_radeon.so` directly.

**To undo this later:**
```bash
rm ~/.config/environment.d/bc250-mesh-shaders.conf
```
Then log out and back in again.

---

## How do I know it worked?

Run this in a terminal:

```bash
VK_ICD_FILENAMES=~/radeon_driconf_icd.x86_64.json vulkaninfo | grep -i "meshShader ="
```

You should see `meshShader = true` appear.

---

## Something went wrong - how do I undo this?

Nothing about this process modifies your original system driver, so
there's nothing to "undo" at the system level. To stop using the
patched driver:

- **Remove the launch option** from Steam (delete the text you added
  in Step 7), or
- **Delete the files entirely:**
  ```bash
  sudo rm /usr/lib/libvulkan_radeon_driconf.so
  rm ~/radeon_driconf_icd.x86_64.json
  rm ~/.drirc
  ```

Your system will go back to behaving exactly as it did before you
started.

---

## Known issues

- Async compute (a GPU performance feature) doesn't work on this chip
  at all - this is a real hardware limitation, not something this
  patch causes or can fix.
- This has only been thoroughly tested with Final Fantasy VII
  Rebirth. Other games requiring mesh shaders should work the same
  way, but haven't all been individually verified.

## Questions or problems?

Open an issue on this GitHub repo with:
- What step you got stuck on
- The exact error message or text you saw
- The output of `vulkaninfo | grep -i "deviceName"` (confirms your
  hardware is actually being recognized as the BC-250)

---

## If a system update breaks this later

CachyOS (and other rolling-release distros) update packages
regularly, and a future Mesa release could change things enough that
this patch stops applying cleanly, or the driver stops working right.

**Download `bc250-rebuild.sh` from this repo** to rebuild everything
automatically instead of repeating all the manual steps above:

```bash
chmod +x ~/Downloads/bc250-rebuild.sh
```

Put it in the same folder as `bc250_driconf_fix.patch`, then run:

```bash
bash ~/Downloads/bc250-rebuild.sh
```

This automatically:
- Backs up your current driver first (so you can always go back)
- Downloads a fresh copy of Mesa and applies the patch
- Builds and installs the new driver
- Checks everything actually worked before finishing - if anything
  goes wrong partway through, it stops and tells you, instead of
  leaving you with a broken driver

If you want to try a specific newer Mesa version instead of the
default one, run it like this:

```bash
bash ~/Downloads/bc250-rebuild.sh mesa-26.3.0
```

(replace `mesa-26.3.0` with whatever version you want to try)

If the patch fails to apply after a Mesa update, the script will
stop and tell you rather than installing something broken - in that
case, please open an issue on this repo so the patch can be updated
for the new Mesa version.
