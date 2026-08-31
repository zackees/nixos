# Working in this repo

This repo *is* the machine `nixos` — an AMD Ryzen 7 3700X workstation running
NixOS 26.05 with KDE Plasma 6 on Wayland. Changing a file here and applying it
changes a real computer someone uses. There is no staging environment.

Read [`README.md`](README.md) for the layout and [`RESTORE.md`](RESTORE.md) if
you are rebuilding the machine from nothing.

## Rules

**Never commit a credential.** No password hashes, no tokens, no keys, no
Wi-Fi PSKs. This is not a style preference: an earlier version of this repo
committed `/etc/shadow` hashes, and removing them required deleting the
GitHub repository outright, because a force-push leaves the objects
retrievable by SHA. `scripts/sync.sh` scans for credentials and aborts the
push; do not weaken its `PATTERN` to get a commit through. If you genuinely
need a secret in the config, use `sops-nix` or `agenix` — never a plain
`.nix` file.

**Never edit `/etc/nixos` directly.** It is overwritten by
`scripts/03-apply-system.sh`. Edit `system/` here; that is the source of
truth. (`/etc/nixos` is still its own local git repo from before this one
existed — ignore it.)

**Never run `nixos-rebuild switch` unprompted.** It activates a new system
generation on a live machine. Use `--build` to verify, and leave activation
to the user unless they asked for it.

**Do not restore KDE files while Plasma is running.** `plasmashell` holds its
own copy in memory and rewrites them on exit, so the restore silently does
nothing. `scripts/04-apply-home.sh` detects this and skips rather than
pretending; that behaviour is deliberate, not a bug to fix.

## Verifying a change to `system/`

Always, before committing:

    sudo nixos-rebuild build -I nixos-config="$PWD/system/configuration.nix"
    echo "exit=$?"

**Check that exit code, and do not pipe the command into `tail`, `head` or
`grep` to shorten the output.** The pipeline's status is the last command's,
so a failed build reports success. Redirect to a file and read it instead:

    sudo nixos-rebuild build -I nixos-config="$PWD/system/configuration.nix" \
      > /tmp/build.log 2>&1; echo "exit=$?"; tail -20 /tmp/build.log

A successful build ends with `Done. The new configuration is /nix/store/...`
and writes a `./result` symlink (gitignored). Building does not activate
anything, so it is safe to run at any time.

## Making a change stick

    scripts/sync.sh -m "short description"

Captures live state into the repo, scans for credentials, shows the diff,
commits and pushes. `--dry-run` stops after the diff; `-y` skips the prompt.
It refuses to run on a dirty tree, because capture overwrites tracked files
wholesale — commit or stash first.

Use `scripts/capture.sh` alone if you need to review or amend before
committing.

**Apply to `/etc/nixos` before you sync.** `capture.sh` copies
`/etc/nixos/configuration.nix` *over* `system/configuration.nix`, so the
sync only does the right thing when `/etc/nixos` is the newer of the two. A
rebuild run with `-I nixos-config="$PWD/system/configuration.nix"` — which
is how the verify step above works — activates straight from the repo and
never writes `/etc/nixos`, leaving the repo ahead. Syncing from there
captures the older file and pushes a commit that silently reverts the change
you just applied. Run `scripts/03-apply-system.sh` first; it copies `system/`
into `/etc/nixos` and rebuilds, and is a no-op activation if you already
switched to the same config. `capture.sh` now refuses when the two disagree,
rather than relying on anyone remembering this.

## Traps specific to this repo

**`plasma-manager` replaces panels wholesale.** The widget list in
`system/configuration.nix` is the *entire* Plasma panel. Anything you omit
disappears at next login — you cannot add one widget by adding one entry
somewhere else.

**A pinned launcher whose icon will not resolve renders as blank space, not
as an error.** Add an app, pin it, and the dock comes back with the right
number of slots and nothing drawn in the new ones -- which reads exactly like
"the launcher never got added". It did get added. The config is correct at
every layer worth checking, including plasmashell's own view of it:

    qdbus org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript '
      var w = panels()[0].widgets("org.kde.plasma.icontasks")[0];
      w.currentConfigGroup = ["General"]; print(w.readConfig("launchers"));'

The failure is Qt caching negative icon lookups for the life of the process.
plasmashell started before the package entered the profile, concluded the
icon did not exist, and never re-checks. `kbuildsycoca6` does NOT fix this --
that rebuilds the *service* cache, a different thing, and was tried first.
Restart the process instead:

    systemctl --user restart plasma-plasmashell.service

Recognise it by the collateral damage: already-working launchers degrade too
(Dolphin falls back to a generic page icon), so a dock that looks half-broken
after an install is this, not a panel that failed to apply.

**Panel changes apply at login, not at `nixos-rebuild switch`.**
plasma-manager only regenerates
`~/.local/share/plasma-manager/scripts/2_desktop_script_panels.sh` and leaves
an autostart entry to run it. Run that script directly to apply now. It is
gated on a hash of the generated JS kept in `last_run_desktop_script_panels`
and no-ops when the layout is unchanged; `rm` that file to force it. It works
on a live session because it drives plasmashell's own `evaluateScript` --
which is the opposite of restoring KDE files underneath a running
plasmashell, and is why that one is safe and the other is not.

**Verify the dock with a screenshot, not with grep.** Three monitors at 2x
scale, so the capture is 10240x4526 and the panel sits on HDMI-A-1:

    spectacle -f -b -n -o /tmp/full.png
    magick /tmp/full.png -crop 1250x110+5120+3660 +repage -resize 190% /tmp/dock.png

`grep launchers= plasma-org.kde.plasma.desktop-appletsrc` reported all nine
entries present while the dock was drawing four. Only the picture was right.

**`plasma-manager` is pinned to `trunk`, not a release.** Its tarball
`sha256` in the `let` block keeps builds reproducible, but bumping it can
bring API changes. Bump `url` and `sha256` together.

**`home/kde/` is captured, not generated.** Those files have no declarative
source; KDE rewrites them at runtime. They go stale whenever a setting
changes in System Settings. `scripts/capture.sh` is the only thing that
refreshes them.

**`scripts/capture.sh` contains a heredoc.** If you edit it by piping a
heredoc from your shell, pick a delimiter it does not already use. A
collision terminates your heredoc early and leaks the rest into the shell,
where redirects like `> system/configuration.nix` still execute and truncate
real files. This has happened; it cost a restore from the last commit.

**`hardware-configuration.nix` is committed with real UUIDs**, and
`scripts/01-partition.sh` recreates those UUIDs, so the two match without
regeneration. Do not regenerate it on a whim. Installing onto different
hardware needs `scripts/02-install.sh --regen-hardware`.

**`docs/hardware.md` is generated** by `scripts/gen-hardware-doc.sh`. Edit
that script, not the output. It deliberately carries no timestamp, so the
file only changes when the hardware does.

## sudo on this machine

One successful authentication unlocks sudo for every session, machine-wide,
for 15 minutes (`timestamp_type=global`). Interactive shells alias `sudo` to
`sudo -A`, which draws a graphical KDE dialog — so in a session with no
terminal, a `sudo` call may be waiting on a dialog the user has to see rather
than hanging. Drop the ticket with `sudo -k`.

**An agent can authenticate itself — use `sudo -A` explicitly.** The alias
only exists in interactive shells, so a tool-invoked shell gets plain `sudo`,
which needs a tty it does not have and fails with "a password is required".
Spelling out `-A` draws the same KDE dialog for the user to answer, and it
works from a non-interactive shell because the environment already carries
everything ksshaskpass needs:

    SUDO_ASKPASS=.../ksshaskpass    WAYLAND_DISPLAY=wayland-0
    DISPLAY=:0                      XDG_RUNTIME_DIR=/run/user/1000

Verified with `sudo -A id` → `uid=0(root)`. Wrap it in `timeout` — if nobody
is at the screen the dialog waits forever, and an un-timed call hangs the
whole tool invocation rather than failing. The 15-minute global ticket then
covers subsequent plain `sudo` calls, which is why an agent usually only
needs to trigger one dialog per burst of work.

Do not reach for this to bypass a refusal: the rules above about
`nixos-rebuild switch` and `/etc/nixos` are about what should happen, not
about what sudo permits.

## Commits

Explain *why*, not what — the diff shows what. Note anything a future reader
would otherwise have to rediscover: a workaround, a pinned hash, a
counter-intuitive constraint. Existing history is the style reference.
