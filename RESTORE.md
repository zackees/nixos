# Restoring this machine from nothing

Written to be followed start to finish by an agent or by a person who has
never seen this machine. Every step says what it does, how to tell it worked,
and what to do when it does not.

Budget roughly 60–90 minutes, most of it unattended downloading.

## Before you start

You need:

- A NixOS 26.05 installer ISO on a USB stick.
  <https://nixos.org/download> → "NixOS: the Linux distribution" → Graphical
  or Minimal, both work. The ISO's own version does not have to match 26.05;
  the installed system's does, and `02-install.sh` pins that channel itself.
- Wired ethernet. The installer needs network, and this machine has no
  wireless configuration (see `docs/manual-state.md`).
- A GitHub token or credentials for `zackees`, to clone this private repo.
  **This is the one thing that cannot come from the repo.** Without it, stop
  here and get it — a Personal Access Token with `repo` scope from
  <https://github.com/settings/tokens> is enough.

You will also be asked to **choose passwords** for `root` and `niteris`
during installation. This repo stores no credentials, so the old passwords
are not recoverable from it — pick new ones, or use the old ones if you know
them.

Read `docs/hardware.md` and confirm you are restoring onto the machine it
describes, or at least onto a UEFI x86-64 machine with an NVMe disk. If the
hardware differs, the restore still works, but see
[Different hardware](#different-hardware) at the end.

## Step 1 — boot the installer and get a shell

Boot from the USB stick. On the graphical ISO, quit the installer wizard and
open a terminal. Then become root:

    sudo -i

Confirm you are in the installer and have network:

    nixos-version          # should print a NixOS version
    ping -c1 github.com    # should get a reply

If `ping` fails, plug in ethernet, then `systemctl restart NetworkManager`.

## Step 2 — get this repo onto the machine

    nix-shell -p git gh

Authenticate, then clone. With a token:

    echo "ghp_YOUR_TOKEN" | gh auth login --with-token
    gh repo clone zackees/nixos /root/nixos

Or with plain git, pasting the token as the password:

    git clone https://github.com/zackees/nixos.git /root/nixos

Check it landed:

    ls /root/nixos/system/configuration.nix    # must exist

## Step 3 — partition the disk

**This erases the disk.** It recreates the exact layout in
`docs/hardware.md`, including the original filesystem UUIDs, which is what
lets the committed `hardware-configuration.nix` be used as-is.

Find the target disk first — it is the 1.8T NVMe on the original machine:

    lsblk -dpo NAME,SIZE,MODEL

Then:

    /root/nixos/scripts/01-partition.sh /dev/nvme0n1

It prints the partitions it is about to destroy and waits for you to type
`ERASE`. Nothing happens before that.

Verify:

    lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINT /dev/nvme0n1

You want `/mnt` and `/mnt/boot` mounted, root labelled `root` with UUID
`ea0caf0b-…`, and boot as vfat with UUID `866F-1102`.

> **Reinstalling without wiping?** Skip this step. Mount the existing
> filesystems at `/mnt` and `/mnt/boot` yourself and go to step 4. Note that
> the second disk (`sda`, 931G of NTFS — a Windows install) is never touched
> by any script here.

## Step 4 — install the system

    /root/nixos/scripts/02-install.sh

This copies `system/` to `/mnt/etc/nixos`, subscribes root to the
`nixos-26.05` channel, and runs `nixos-install`.

Expect a long download. Near the end it prompts twice:

1. `nixos-install` asks for the **root** password.
2. The script then asks for the **niteris** password, setting it inside the
   installed system with `nixos-enter`. Do not skip this — `niteris` is
   created by `configuration.nix` but has no password until one is set, and
   an account with no password cannot log in at SDDM. If you do skip it, boot
   the machine, log in as `root` on a text console, and run `passwd niteris`.

When it finishes:

    reboot

Remove the USB stick as it goes down.

**Checkpoint:** the machine boots to the SDDM login screen, and `niteris`
logs in with the password you just set. If it boots to a console
instead, the desktop failed to start — log in on the console and check
`systemctl status display-manager`.

## Step 5 — restore user state

Log in as `niteris` and open a terminal (Konsole; kitty is installed but is
not yet configured).

Re-authenticate to GitHub and clone the repo into place:

    gh auth login                       # HTTPS, paste the token
    mkdir -p ~/dev && gh repo clone zackees/nixos ~/dev/nixos

KDE settings must be restored with Plasma stopped, or plasmashell overwrites
them on the way out. The clean way:

1. `ctrl+alt+F3` to a text console, log in as `niteris`
2. run `~/dev/nixos/scripts/04-apply-home.sh`
3. `ctrl+alt+F1` back, and log out and in again

If you would rather do it from inside the desktop, run it as
`KDE_FORCE=1 ~/dev/nixos/scripts/04-apply-home.sh` and log out
*immediately* afterwards. Without `KDE_FORCE=1` the script detects Plasma and
skips the KDE portion rather than doing something that will not stick.

The script also installs `uv` and the `clud` and `soldr` CLI tools, and
restores the kitty config, the voxtype dictation config, and the shell
aliases.

## Step 6 — log out and back in

Required, not optional. Two things only take effect in a fresh session:

- membership in the `ydotool` group, without which dictation cannot type
- the `Meta+H` global shortcut, which KDE reads at session start

## Step 7 — verify

Run these as `niteris` in a normal desktop session:

    # desktop
    echo $XDG_SESSION_TYPE            # wayland
    plasmashell --version             # plasmashell 6.x

    # the panel, declared by plasma-manager: kickoff, pager, task icons,
    # per-core CPU + memory + disk monitors, TMOG and display shortcuts,
    # system tray, clock
    #   -> check this visually along the bottom of the screen

    # terminal
    kitty --version
    readlink ~/.config/kitty/kitty.conf   # -> /home/niteris/dotfiles/kitty/kitty.conf

    # shell tooling
    type ls                            # aliased to eza
    rg --version; fd --version; bat --version; lazygit --version
    starship --version
    cd --help | head -1                # zoxide, not builtin cd

    # sudo: graphical prompt, 15-minute machine-wide ticket
    grep timestamp /etc/sudoers
    cat /etc/sudo.conf                 # Path askpass .../ksshaskpass

    # dictation
    id -nG | tr ' ' '\n' | grep -x ydotool
    systemctl --user is-active voxtype
    systemctl is-active ydotoold
    # then press Meta+H, speak, press Meta+H again -- text types at the cursor

    # tools
    uv tool list                       # clud, soldr
    gh auth status                     # logged in as zackees

    # no credentials crept into the repo during the restore
    ~/dev/nixos/scripts/sync.sh --dry-run

Anything that fails here is a real regression — the same commands pass on the
machine this repo was captured from.

## Step 8 — the last interactive bits

Nothing below can be automated; see `docs/manual-state.md` for why.

- `claude` — run it once; it opens a browser to sign in to Anthropic.
- Brave and Firefox — sign in to sync if you use it. Profiles are not in this
  repo.
- Audio — the machine has a Focusrite Scarlett 2i2, an Elgato Wave:3 and a
  Cam Link 4K. `alsa-scarlett-gui` is installed for the 2i2's 48V, gain, air
  and pad controls. voxtype records from the PipeWire default source; if it
  picks the wrong one, set `device` in `~/.config/voxtype/config.toml` to a
  name from `pactl list sources short`.
- Displays — three of them (see `docs/hardware.md`). The captured
  `kwinoutputconfig.json` matches them by EDID hash, so the arrangement and
  per-screen scaling should return by itself. Re-arrange in System Settings →
  Display if not, then run `scripts/capture.sh` to record the new layout.

## Different hardware

If the disk, its size, or the machine itself is not what `docs/hardware.md`
describes:

- Skip `01-partition.sh` and partition by hand, or edit the sizes in it.
- Run the installer with `02-install.sh --regen-hardware`, which scans the
  live machine and writes a fresh `hardware-configuration.nix` instead of
  using the committed one.
- Afterwards, copy the generated `/etc/nixos/hardware-configuration.nix` back
  into `system/` and commit it, or `scripts/capture.sh` will do it for you.

The rest of the configuration is hardware-independent, with one exception:
`boot.loader.systemd-boot` assumes UEFI. On a BIOS-only machine you would
need `boot.loader.grub` instead.

## When something goes wrong

**The build fails on an evaluation error.** The config pins
`home-manager` (release-26.05) and `plasma-manager` (trunk) by tarball hash
in the `let` block of `system/configuration.nix`. `plasma-manager` tracks
trunk, so it can move under you and stop matching its hash or its API. Bump
the `url`/`sha256` pair together, or pin `plasma-manager` to a release tag.

**The Plasma panel is empty or wrong.** plasma-manager *replaces* panels
wholesale rather than merging — the widget list in `configuration.nix` is the
entire panel. Anything missing there will not appear.

**A KDE setting did not survive.** It was almost certainly restored while
Plasma was running. Redo step 5 from a TTY.

**You want the previous system back.** NixOS keeps every generation. Pick an
older one from the systemd-boot menu at power-on, or:

    sudo nixos-rebuild switch --rollback
