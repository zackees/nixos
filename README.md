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
| 1 | **System**, declarative | `system/` | `nixos-install`, then `nixos-rebuild switch` |
| 2 | **User state** NixOS cannot reach | `home/` | `scripts/04-apply-home.sh` |
| 3 | **Facts about the machine** | `docs/` | read by a human; nothing executes them |

Layer 1 is the real configuration: packages, fonts, services, aliases, the
sudo policy, the dictation setup, and — via home-manager and plasma-manager
pinned inside `configuration.nix` — the Plasma panel. Change things there by
preference.

Layer 2 exists because KDE writes its own settings files at runtime and there
is no declarative source for most of them. Those files are *captured*, not
generated, so they can drift; `scripts/capture.sh` pulls them back in.

## Layout

    system/
      configuration.nix          the machine: packages, services, desktop, sudo
      hardware-configuration.nix disks and kernel modules (UUIDs are real)

    home/
      bash/                      .bashrc, .bash_profile
      kitty/                     terminal config; deployed to ~/dotfiles/kitty
      kde/                       captured Plasma/KDE/GTK settings files
      voxtype/                   dictation daemon config
      applications/              the .desktop entry Meta+H launches
      tools/                     claude, clud and gh non-secret settings

    scripts/
      01-partition.sh            DESTRUCTIVE; recreates the disk layout
      02-install.sh              nixos-install onto /mnt
      03-apply-system.sh         copy system/ to /etc/nixos and rebuild
      04-apply-home.sh           restore per-user state
      sync.sh                    capture + commit + push, in one command
      capture.sh                 pull live state back into this repo
      gen-hardware-doc.sh        regenerate docs/hardware.md

    docs/
      hardware.md                CPU, disks, displays (generated)
      manual-state.md            what deliberately is NOT in this repo

## Everyday use

Change the system:

    $EDITOR system/configuration.nix
    scripts/03-apply-system.sh --build     # evaluate without activating
    scripts/03-apply-system.sh             # activate
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

`scripts/03-apply-system.sh` copies into `/etc/nixos` rather than symlinking,
so `/etc/nixos` stays a plain directory that works even if this checkout is
missing. The consequence is that the two can diverge — `capture.sh` is how
you notice.

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
