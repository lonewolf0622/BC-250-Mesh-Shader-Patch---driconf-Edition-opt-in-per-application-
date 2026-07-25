# BC-250 Mesh Shader Patch - driconf Edition (opt-in, per-application)

Enables mesh shader support on the AMD BC-250 (GFX1013), scoped to
specific applications only, via Mesa's driconf system. Unlike the
basic version of this patch, this one is **off by default for every
application** and only activates for games you explicitly list in
`~/.drirc` (or `/etc/drirc` for a system-wide config). This lets you
install the modded driver as your system's default Vulkan driver
without it affecting anything except the games you opt in.

## Why this version exists

The basic patch always forces GFX1013 to report as GFX10_3. That
works, but it means the driver always behaves this way for every
Vulkan application on the system. This version makes that behavior
opt-in per-application, so you can safely replace your system's
default driver (`/usr/lib/libvulkan_radeon.so`) with this build
without worrying about unintended side effects on other software.

## Build instructions

Same as the basic patch:

```bash
mkdir -p ~/bc250-mesa-build && cd ~/bc250-mesa-build
git clone --depth 1 --branch mesa-26.1.4 https://gitlab.freedesktop.org/mesa/mesa.git mesa
cd mesa
patch -p1 --fuzz=5 -i /path/to/bc250_driconf_fix.patch

python3 -m venv venv
venv/bin/pip install meson
VENV="$HOME/bc250-mesa-build/mesa/venv"
PYTHONPATH="$VENV/lib/python3"*/site-packages "$VENV/bin/meson" setup build \
  -Dvulkan-drivers=amd -Dgallium-drivers=zink \
  -Dglx=disabled -Degl=disabled -Dgles2=disabled \
  -Dshared-llvm=disabled -Dllvm=disabled \
  -Dxmlconfig=disabled -Dlmsensors=disabled -Dvalgrind=disabled

PYTHONPATH="$VENV/lib/python3"*/site-packages ninja -C build src/amd/vulkan/libvulkan_radeon.so
```

## Installation - two options

### Option A: Per-game launch option (safest, no system changes)

```bash
sudo cp build/src/amd/vulkan/libvulkan_radeon.so /usr/lib/libvulkan_radeon_driconf.so

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

Steam launch options:
```
VK_ICD_FILENAMES=/home/YOURUSER/radeon_driconf_icd.x86_64.json %command%
```

### Option B: Replace the system default driver (no launch option needed)

**Back up your original driver first - this is important:**

```bash
sudo cp /usr/lib/libvulkan_radeon.so ~/libvulkan_radeon_ORIGINAL_BACKUP.so
sudo cp build/src/amd/vulkan/libvulkan_radeon.so /usr/lib/libvulkan_radeon.so
```

Verify basic Vulkan still works before launching any game:
```bash
vulkaninfo | head -20
```

If anything goes wrong (black screen, crashes, unusable desktop),
switch to a text console (`Ctrl+Alt+F3`) and restore the backup:
```bash
sudo cp ~/libvulkan_radeon_ORIGINAL_BACKUP.so /usr/lib/libvulkan_radeon.so
```

## Enabling the spoof for a specific game

Since the option defaults to off, create or edit `~/.drirc`:

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

**Important:** match the `executable` value against the real process
name, not just the visible filename - Proton/Wine sometimes reports
a slightly different name (in FF7 Rebirth's case, it's
`ff7rebirth_.exe` with a trailing underscore, not `ff7rebirth.exe`).
To find the real name for any game, launch it and run:

```bash
for pid in $(pgrep -i "your_game_keyword"); do
  echo "PID $pid: $(cat /proc/$pid/comm)"
done
```

To add more games later, add another `<application>` block inside
the same `<device>` section.

## Verify it worked

```bash
VK_ICD_FILENAMES=~/radeon_driconf_icd.x86_64.json vulkaninfo | grep -i "meshShader ="
```
(or without the `VK_ICD_FILENAMES` override, if using Option B)

Should show `true` only when running as the configured application;
any other Vulkan app on the system will see GFX1013's real, honest
`gfx_level`.

## Known limitations

- Async compute remains unavailable on this chip (genuine hardware
  bug, documented in Mesa's own source) - unaffected by this patch.
- If you use Option B (system-wide driver replacement) and later want
  to revert entirely, just restore your backup file.
