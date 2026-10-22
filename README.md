# nixos

The complete configuration of `nixos`, an AMD Ryzen 7 3700X workstation
running NixOS 26.05 with KDE Plasma 6 on Wayland.

The repository is private, but it holds **no credentials** — no password
hashes, no tokens, no keys. That is enforced, not just intended:
`scripts/sync.sh` scans for them and refuses to push. See
[Secrets](#secrets) for the two passwords a restore asks you to type instead.

## What this is for

One goal: after a full wipe, a person — or an agent — can turn a blank disk
back into this machine by following [`RESTORE.md`](RESTORE.md), without
having to remember anything that was not written down.

That means the repo holds three different kinds of thing, and it is worth
knowing which is which:

| | Layer | Lives in | Restored by |
|---|---|---|---|
| 1 | **System**, declarative | `flake.nix`, `system/` | `nixos-install --flake`, then `nixos-rebuild switch --flake` |
| 2 | **User state** NixOS cannot reach | `home/` | `scripts/03-apply-home.sh` |
| 3 | **Facts about the machine** | `docs/` | read by a human; nothing executes them |

Layer 1 is the real configuration: packages, fonts, services, aliases, the
sudo policy, the dictation setup, and — via home-manager and plasma-manager,
which are flake inputs — the Plasma panel. Change things there by preference.

`flake.lock` pins nixpkgs, home-manager and plasma-manager by revision, so
two restores months apart build the same machine. Moving any of them is
`nix flake update`, which shows up as a reviewable diff in a commit rather
than as whatever a channel happened to serve that day.

Layer 2 exists because KDE writes its own settings files at runtime and there
is no declarative source for most of them. Those files are *captured*, not
generated, so they can drift; `scripts/capture.sh` pulls them back in.

## GPU assignments

The RTX 3060 at PCI `06:00.0` drives the desktop and voxtype. The modified
RTX 2080 Ti at `07:00.0` has 22 GiB of VRAM and is reserved for ML workloads.
`system/configuration.nix` restricts both KWin's display and render devices
to the 3060. Ordinary CUDA programs and services see only the 3060 by default;
voxtype is also explicitly pinned to it. KWin's restriction takes effect at
the next login. Open a new shell after changing the CUDA default.

Launch CUDA model workloads on the 2080 Ti with:

    ml-gpu python train.py
    ml-gpu llama-server -m /path/to/model.gguf --n-gpu-layers 99
    ml-gpu ollama serve

Interactive shell aliases automatically apply `ml-gpu` to `llama-server`,
`llama-cli`, `llama-bench`, `llama-perplexity`, `ollama`, and `vllm`.
The launcher selects the GPU; the runtime's own options still control whether
and how much of the model is offloaded. These commands do not install runtimes.

Scripts and GUI launchers should use `ml-gpu` explicitly. A model service
should set `CUDA_VISIBLE_DEVICES=GPU-a1c3881b-3372-4320-5cf3-ea672f86e2d0`
in its service environment. Set the server's environment when starting it:
changing an Ollama client's environment does not move an existing server.

CUDA and `nvidia-smi` can enumerate these cards differently, so assignments
use UUIDs. CUDA's masking makes the selected GPU appear as device 0 inside
the program. This policy applies to CUDA runtimes, including PyTorch and CUDA
builds of llama.cpp; Vulkan runtimes need their own GPU selection. Programs
can override the policy explicitly. There is no automatic routing based on
model size or a later request for VRAM.

## Layout

### Calendar reminders

The compact **Today** tab beside the top-panel clock is roughly the clock's
width. Hover or click for the next meeting's title, start time and countdown,
and today's full agenda, including all-day and completed events.
Current meetings are highlighted and completed meetings dimmed. Click a Zoom
meeting to join it, or another event to open its calendar page; the calendar
button opens KOrganizer. The tab refreshes every 30 seconds from the existing
private local calendar, without another Google connection. No meeting data or
joining links are stored in this repository. The widget and reader live in
`system/calendar-agenda/` and `system/calendar-agenda.py`.

KOrganizer is pinned to the dock. `calendar-sync.service` reads Google Calendar
every minute into a read-only local calendar: yesterday through the next 90 days,
including recurring instances and pending invitations. Timed events have popup
reminders ten minutes before and at the start; all-day events have no midnight
alarm. KDE's Calendar Reminders runs at login and provides persistent popups with
snooze, dismiss and view actions even with KOrganizer closed. Calendar popups
remain visible for up to one hour unless dismissed or snoozed, including when
a short event has already ended. New future events
and invitations get a separate notification after the first, quiet sync.
Each new-event popup also gets an independent systemd wall-clock timer that
explicitly closes it within one hour, even if Plasma pauses its popup timeout
or calendar sync restarts. The timer targets the original notification server
instance so a Plasma restart cannot make it close an unrelated popup.

This connection does not edit Google events or accept invitations. Use the event's
Google Calendar link to edit or respond. Only calendars shared with the service
account are accessible; invitations must be visible on that calendar.

After restoring, provision `~/.config/calendar-sync/service-account.json` from the
private booking project's Google service account key, and create
`~/.config/calendar-sync/config.json` with `credentials` (the absolute key path)
and `calendar_id` (the shared Google calendar ID). Keep the directory mode 0700
and both files 0600. Neither file belongs in this repo or the Nix store. Then:

```bash
systemctl --user start calendar-sync app-org.kde.kalendarac@autostart
```

The sync creates its Akonadi calendar resource automatically. An API outage leaves
the last calendar intact, with existing reminders still available; sync retries
every minute. Check `journalctl --user -u calendar-sync` for connection failures.

### KDE Shader Wallpaper

KDE Shader Wallpaper is installed system-wide and selected for Plasma's lock
screen, using Nimitz's animated aurora shader at 30 FPS on every display.
Choose another shader under System Settings → Screen Locking → Configure
Appearance → Shader Wallpaper. Its gallery includes Shadertoy imports and
multi-pass effects. The plugin is built against the same Qt and Plasma
packages as the desktop; update its pinned source in `flake.nix` deliberately.
The package is declared in `system/kde-shader-wallpaper.nix`, with settings in
`system/shader-wallpaper.nix`. Plasma locks after **ten idle minutes** and shows
the shader on all three monitors. A password is required to resume. Display
power-off remains at 30 idle minutes; automatic suspend is disabled. Plasma
handles playback inhibitors and locking directly; no separate screensaver
daemon is needed. Press `Meta+L` to show the shader and lock immediately.

### Dictation playback ducking

Voxtype's recording and transcription notifications use a separate popup in the
lower-right corner of the main (largest) monitor. `voxtype-popup.service` owns
one replaceable popup; text is plain, scrollable, and dismissible. Its private
`notify-send` replacement is confined to the Voxtype daemon, so Telegram and
other Plasma notifications retain their upper-right placement. The microphone
waveform overlay is configured separately in `home/voxtype/config.toml`.

Recordings shorter than 500 ms of captured audio are discarded immediately,
before voice detection or transcription. Startup cue time does not count toward
this minimum; a clip of exactly 500 ms is accepted for normal processing.

Before Voxtype opens the microphone, a synchronous `--prepare` hook reduces
every physical playback device by 12 dB. The start cue plays to completion,
then capture waits another 75 ms for its acoustic tail. The local Voxtype patch
moves `pre_recording_command` before capture (upstream calls it afterwards)
and plays the stop cue only after capture closes, keeping both cues out of
transcription. `voxtype-ducking.service` holds attenuation throughout the
`preparing` and `recording` states; it shares a locked recovery journal with
the preparation hook so overlapping updates cannot double-duck the volume.
Audio keeps playing and
returns to its previous level when capture ends, before transcription.
Microphone levels, per-app volumes and the virtual OBS mix are unaffected.
Manual output-volume changes during dictation take precedence over restoration.
The helper also restores saved levels on shutdown or crash recovery.

Temporarily stop ducking with `systemctl --user stop voxtype-ducking`.
It starts with Voxtype again at login or when Voxtype restarts.

### Files

    flake.nix                    inputs: nixpkgs, home-manager, plasma-manager
    flake.lock                   their exact revisions; the reproducibility

    system/
      configuration.nix          the machine: packages, services, desktop, sudo
      hardware-configuration.nix disks and kernel modules (UUIDs are real)

    home/
      bash/                      .bashrc, .bash_profile
      kitty/                     terminal config; deployed to ~/dotfiles/kitty
      kde/                       captured Plasma/KDE/GTK settings files
      voxtype/                   dictation daemon config
      obs/                       recording path/filename settings (captured)
      applications/              the .desktop entry Meta+H launches
      tools/                     claude, clud and gh non-secret settings
      sublime/                   Sublime Text preferences (captured)

    scripts/                     numbered = the restore, run in order, once
      01-partition.sh            DESTRUCTIVE; recreates the disk layout
      02-install.sh              nixos-install onto /mnt, then reboot
      03-apply-home.sh           restore per-user state, after first login

                                 unnumbered = any time, on a live machine
      sync.sh                    capture + commit + push, in one command
      capture.sh                 pull live state back into this repo
      gen-hardware-doc.sh        regenerate docs/hardware.md

    docs/
      hardware.md                CPU, disks, displays (generated)
      manual-state.md            what deliberately is NOT in this repo

## Everyday use

Change the system:

    $EDITOR system/configuration.nix
    nixos-rebuild build --flake .#nixos         # evaluate without activating
    sudo nixos-rebuild switch --flake .#nixos   # activate
    git commit -am "..."

Something was changed by hand — a KDE setting, a display arrangement — and
should be kept:

    scripts/sync.sh -m "kde: three-monitor layout"

That is the one command to remember. It pulls the live state into the repo,
scans it for anything credential-shaped, shows you the diff, then commits and
pushes. `-y` skips the prompt, `--dry-run` stops after the diff. It refuses
to run on a dirty tree, since capturing overwrites tracked files wholesale.

`scripts/capture.sh` is the capture step alone, if you want to review or
amend before committing.

`nixos-rebuild --flake` builds from this checkout directly. Nothing is copied
into `/etc/nixos`, so the repo is the only copy and there is no second one to
drift out of step with it — which is why `capture.sh` no longer touches
`system/` at all.

The cost is that the checkout has to be present to rebuild, and that flakes
only see files git *tracks*: a brand-new `.nix` file is invisible until it is
`git add`ed, and the error looks like the file does not exist.

## Secrets

There are none in here, deliberately, and one script enforces it.

Passwords are the interesting case. A restore could carry the `/etc/shadow`
hashes and boot straight to a working login, but that would make the repo's
privacy load-bearing — a yescrypt hash is offline-crackable, so a leak would
mean rotating passwords *and* rewriting history. The cost of not carrying
them is one prompt: `scripts/02-install.sh` asks for the root and `niteris`
passwords during installation, and the machine still boots ready to use.
`users.mutableUsers` stays at its default `true`, so `passwd` is the only
thing that ever sets them.

`scripts/sync.sh` scans every captured file for password hashes, GitHub and
Anthropic tokens, AWS keys, private keys and Wi-Fi PSKs, and aborts the push
if it finds one. This matters because `home/kde/` and `home/tools/` are
captured verbatim from live settings files, which could start carrying a
token at any upgrade. `system/secrets.nix` is also in `.gitignore`, so a
local one cannot be committed by accident.

The rest — GitHub token, Anthropic credentials — stays out for the reasons in
[`docs/manual-state.md`](docs/manual-state.md), which also records what does
not exist on this machine at all (no Wi-Fi passwords, no SSH keys), so a
restore does not go looking.

Browser profiles, shell history and `~/Documents` are data, not
configuration. Back those up separately.
