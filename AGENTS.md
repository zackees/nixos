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

**`/etc/nixos` is not used at all any more.** Since the flake migration
`nixos-rebuild --flake` builds from this checkout, and nothing writes
`/etc/nixos`. Edit `system/` here; it is the only copy. (`/etc/nixos` is
still its own local git repo from before this one existed, now purely
vestigial — ignore it, and do not "resync" it.)

**A new `.nix` file is invisible until `git add`.** Flakes only see files
git tracks, so an uncommitted addition fails with an error that reads as if
the file does not exist. Modifying an already-tracked file is fine.

**Never run `nixos-rebuild switch` unprompted.** It activates a new system
generation on a live machine. Use `nixos-rebuild build --flake` to verify, and leave activation
to the user unless they asked for it.

**Ask whether a new GUI application belongs on the dock.** Installing one
and pinning it are separate decisions, and both mistakes have been made here:
kdenlive and handbrake went in and sat unpinned until someone noticed they
were missing, while podman-desktop was pinned without anyone being asked.
The panel is declared in
`system/configuration.nix` and replaced wholesale, so a pin is a deliberate
edit to that list, never a side effect of adding a package. Ask, and do not
assume either way. If the answer is yes, the pin, the panel apply and the
plasmashell restart all go together -- see the panel traps below.

**Do not restore KDE files while Plasma is running.** `plasmashell` holds its
own copy in memory and rewrites them on exit, so the restore silently does
nothing. `scripts/03-apply-home.sh` detects this and skips rather than
pretending; that behaviour is deliberate, not a bug to fix.

## Verifying a change to `system/`

Always, before committing:

    nixos-rebuild build --flake .#nixos
    echo "exit=$?"

**Check that exit code, and do not pipe the command into `tail`, `head` or
`grep` to shorten the output.** The pipeline's status is the last command's,
so a failed build reports success. Redirect to a file and read it instead:

    nixos-rebuild build --flake .#nixos \
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

**"Apply" means both halves, and it ends with a clean tree.** When the user
says apply -- "apply changes", "apply updates", "apply it" -- that is the
prompting that lifts the `nixos-rebuild switch` rule above, *and* it asks for
`scripts/sync.sh` afterwards. Do not stop at the switch and report success.
Activating alone leaves the machine ahead of the repo with the edits still
uncommitted, and that is precisely the state `scripts/sync.sh` refuses to run
in and the next `scripts/capture.sh` would overwrite -- so the tidying gets
harder the longer it waits, and the work can be lost outright.

Confirm before the push, since that part is outward-facing and irreversible,
but confirm having already switched and captured, with the diff on screen.
The same goes for an agent's own working state: never end a turn with edits
sitting loose in the tree because the sync looked like a separate task. It is
the second half of the same one.

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
`kbuildsycoca6` does NOT fix this -- that rebuilds the *service* cache, a
different thing, and was tried first. Restart the process instead:

    systemctl --user restart plasma-plasmashell.service

**Treat that restart as the last step of every panel apply, not as a fix for
a broken one.** The first time this appeared it looked like a consequence of
installing packages after plasmashell had started. It is not: it came back on
the very next panel rebuild, one that only reordered launchers and installed
nothing at all. Rebuilding the panel is itself what leaves the icons
unresolved, so the script below and this restart go together every time.

Recognise it by the collateral damage: already-working launchers degrade too
(Dolphin and System Settings fall back to a generic page icon), so a dock
that looks half-broken is this, not a panel that failed to apply.

Screenshot only once the shell is actually back. Capture too early and the
frame is solid black, or catches the panel mid-relayout with the icons in the
wrong place -- both look like real failures and are not.

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
scale, so the capture is 10240x4526 and the panel sits on HDMI-A-1. Widen the
crop as launchers are added -- it is currently thirteen:

    spectacle -f -b -n -o /tmp/full.png
    magick /tmp/full.png -crop 1450x120+5120+3630 +repage -resize 175% /tmp/dock.png

`grep launchers= plasma-org.kde.plasma.desktop-appletsrc` reported all nine
entries present while the dock was drawing four. Only the picture was right.

**A panel rebuild wipes the desktop MOUSE BINDINGS too.** Same file: the
back/forward-button desktop stepping lives in `[ActionPlugins][0]` of
`appletsrc`, written by `3_desktop_script_desktop_step_buttons.sh`. After
running the panel script by hand, run that one too, then restart
plasmashell -- it is `runAlways`, so no `last_run` file to remove. Pinning
Slack silently lost the bindings once.

**A panel rebuild wipes the DESKTOP too.** The generated
`2_desktop_script_panels.sh` opens by deleting
`plasma-org.kde.plasma.desktop-appletsrc` outright (upstream's guard against
that file growing without bound), and that file holds the desktop
containments as well as the panels. So anything placed on the desktop by hand
-- a launcher icon, a widget -- disappears at the next panel apply, with no
backup and nothing in the output to say so. It has already cost one icon here.
Declare desktop widgets in `programs.plasma.desktop.widgets` instead; that
list is wholesale like `panels` is, and it re-adds them after every rebuild.

Files in `~/Desktop` are unaffected -- this only eats *widgets*.

**plasma-manager's panel `opacity` option does nothing on Plasma 6.6.6.** It
emits `panel.opacity = "..."` and plasmashell ignores it: the getter keeps
saying `adaptive`, no `panelOpacity` is written, and setting it by hand on a
live panel changes nothing either -- while `panel.hiding` in the same script
works, so the bridge itself is fine. The setting is real
(`[PlasmaViews][Panel <id>] panelOpacity` in `plasmashellrc`, 0 adaptive /
1 opaque / 2 translucent), it just has to be written directly, and the id is
regenerated on every panel rebuild -- see the `panel-opacity` startup script
in `system/configuration.nix` for the shape that survives that.

**A panel with no `screen` set moves house on its own.** Both panels in
`system/configuration.nix` now carry `screen = 0`, and that is load-bearing:
an unset screen is an unspecified one, not "the primary". plasma-manager
emits no `lastScreen` and plasmashell places the panel wherever it likes, so
every panel rebuild re-rolls it. Adding one launcher to the dock was enough
to move BOTH panels off the primary 4K onto the small top-left monitor.

The index is Plasma's own numbering, not a connector name, so System Settings
rearranging the monitors can renumber it. Read the current mapping back with:

    qdbus org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript '
      for (var i = 0; i < screenCount; i++) {
        var g = screenGeometry(i); print(i + ": " + g.x + "," + g.y); }
      var p = panels();
      for (var j = 0; j < p.length; j++) print(j + " -> " + p[j].screen);'

**A `shortcuts.kwin` change is not live until KWin restarts, and do not try
to hurry it.** plasma-manager writes `kglobalshortcutsrc` at activation, but
on this Wayland session the global-shortcut daemon lives *inside*
`kwin_wayland` (libKGlobalAccelD is loaded into it), and it holds the old
bindings in memory. `systemctl --user restart plasma-kglobalaccel.service`
does nothing useful -- the unit goes inactive and KWin keeps answering -- and
poking `org.kde.kglobalaccel` over D-Bus to force a reload is what crashed
KWin on 2026-09-03: `dbus: type invalid 0 not a basic type`, SIGABRT in
`operator>>(QDBusArgument, QSet<QKeySequence>)`, the whole compositor down
for a second. KWin's crash-restart happened to reread the file, which is the
only reason the new keys then worked. Read the live state with

    qdbus --literal org.kde.kglobalaccel /component/kwin \
      org.kde.kglobalaccel.Component.allShortcutInfos

and if it disagrees with the file, tell the user the keys land at next
login (or a deliberate KWin restart) and leave it there.

**"GPU Recovery Action: Reboot" does not mean you have to reboot.** A CUDA
fault can wedge the driver so that every new process gets `failed to
initialize CUDA: unknown error` while `nvidia-smi` keeps working perfectly --
nvidia-smi uses NVML, not CUDA, so it is not the test. The kernel log names
the real event:

    NVRM: Xid 31 ... MMU Fault: ENGINE CE2_PBDMA0 ...
    NVRM: nvGpuOpsReportFatalError: uvm encountered global fatal error 0x60,
          requiring os reboot to recover.
    NVRM: Xid 154, GPU recovery action changed from None to Node Reboot Required

Both the driver message and `nvidia-smi -q | grep "GPU Recovery Action"` ask
for a reboot. On this machine they were wrong: the fatal state lived in
`nvidia_uvm`'s software state, and reloading that one module cleared it with
no reboot and without disturbing the display --

    sudo modprobe -r nvidia_uvm && sudo modprobe nvidia_uvm

`nvidia_uvm` can come out while `nvidia_drm` and `nvidia_modeset` stay
loaded, because nothing but CUDA holds it: check `lsmod | grep nvidia_uvm`
shows refcount 0 first. Verified end to end -- voxtype went from CPU
fallback back to `whisper_backend_init_gpu: using CUDA0 backend` and a 0.19s
transcription. Note that `nvidia-smi` STILL reported "Reboot" afterwards
with CUDA demonstrably working, so that flag is sticky and is not evidence
either way. Try the module reload before taking the machine down.

What put the GPU in that state is worth knowing too: an idle S3 suspend and
immediate resume, the same round trip the powerdevil block in
`system/configuration.nix` now exists to prevent. The GL context loss it
causes is the *visible* half (blank kitty, plasmashell respawn); this UVM
fault is the quieter half, and it only shows up the next time something asks
for CUDA. If both appear on the same evening, suspect one cause.

**Boatswain's buttons are a JSON file, not a GUI-only setting.** The Stream
Deck's whole configuration is `~/.local/share/<serial>.json`, editable by hand.
Boatswain rewrites it on save and on quit, so it must be stopped first --
the same trap as plasmashell and `appletsrc`. Do not try to automate its GTK
UI with `ydotool`; that was attempted and is a dead end on this multi-monitor
fractional-scaling setup.

Stopping it is fiddlier than it looks: `pkill -x boatswain` matches nothing
(the wrapper makes the process name `.boatswain-wrap`), `pkill -f
boatswain-wrapped` kills your own shell, and a second launch of a
single-instance GApplication silently hands off and exits.

The file format, the desktop-id rules that make a button bind or silently not,
and the upstream sources that define them are in
[`.claude/skills/streamdeck/SKILL.md`](.claude/skills/streamdeck/SKILL.md).
Add to that skill whenever you learn something there worth not rediscovering.

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

**NixOS calls the system bashrc `/etc/bashrc`, and kitty looks for
`/etc/bash.bashrc`.** kitty injects its shell integration by starting `bash
--posix`, which skips bash's compiled-in `SYS_BASHRC`; it then sources a
system bashrc back by hand, but its list is Debian's `/etc/bash.bashrc` and
Void's `/etc/bash/bashrc`. Neither exists here, so nothing matched and a kitty
shell got *none* of NixOS's interactive setup -- no starship prompt, no
`environment.shellAliases`, no zoxide `cd`, no direnv, no completion. Just
`bash-5.3$`.

`home/bash/bashrc` sources `/etc/bashrc` explicitly to close this, and must
keep doing so. The symptom misreads badly in both directions: it looks like
starship or the aliases are broken system-wide, when in fact everything in
`configuration.nix` is correct and only kitty cannot see it. Konsole hides the
whole thing, because it runs a *login* shell and `/etc/profile` pulls
`/etc/bashrc` in -- so "works in Konsole, broken in kitty" is the signature.
Test a change to either file in a *newly opened* kitty window; the shells
already running kept whatever they started with.

**`pip` belongs to `~/.venv`, and that venv must not be built on
`pkgs.python3`.** nixpkgs' python ships PEP 668's `EXTERNALLY-MANAGED`, so
`pip install` refuses rather than writing to the immutable `/nix/store`. The
answer is the user venv that `systemd.user.services.user-python-venv` builds
and that `environment.sessionVariables.PATH` puts ahead of the system python
-- not `--break-system-packages`, which scatters packages into
`~/.local/lib/pythonX.Y/site-packages`, a directory on `sys.path` for *every*
interpreter here and silently orphaned the day nixpkgs moves 3.13 to 3.14.

Build it on the uv-managed CPython under `~/.local/share/uv/python`, never on
`pkgs.python3`. A venv records its interpreter's absolute path in
`pyvenv.cfg`; on the store python that path is a `/nix/store` entry which the
next `nix-collect-garbage` deletes, and the venv then dies with "no such file
or directory" for an interpreter that worked yesterday. Same reasoning sets
`PIPX_DEFAULT_PYTHON`: pipx builds each app its own venv, and those rot the
same way. The interpreter version is pinned once as `userPythonVersion` in
the `let` block because it appears in all three places.

**A binary wheel that installs fine can still fail to import.** numpy, pillow
and torch link against `libstdc++` and friends, which exist at no standard
path here; they resolve only because `programs.nix-ld.enable` is on. Without
it `pip install` reports success and the *import* is what breaks, so nix-ld
and the venv are one setting in two places. Test a change to either with an
actual `import`, not with a successful install.

**A package in `systemPackages` whose own test suite fails takes the whole
rebuild down.** `pipx` 1.8.0 on the 26.05 channel fails seven assertions in
`tests/test_package_specifier.py` -- `packaging` >= 24 normalises `black@ url`
to `black @ url` and the tests still expect the old spelling. That is
cosmetic and upstream, but it fails `system-path`, and the error names
`system-path` rather than the package, which reads like a config mistake. The
fix is a narrow `overridePythonAttrs` adding the one file to
`disabledTestPaths`; verify such an override with `nix-build` on the package
alone before rebuilding the system, because the feedback loop is far shorter.

**`uv` is declared in `scripts/03-apply-home.sh`, not in
`configuration.nix`, and that is deliberate.** The pinned nixpkgs' uv lags
while `clud` and `soldr` track PyPI, so the restore installs uv into the
*user nix profile* instead, from a fully-spelled nixpkgs-unstable URL.
Writing that as `nixpkgs#uv` would now resolve through the system flake
registry to this repo's *locked* nixpkgs and install the very version being
avoided — the same trap as below, sprung by a different mechanism. Adding `uv` to `environment.systemPackages` looks
like tidying an undeclared dependency and is not: it puts uv on PATH, which
satisfies that script's guard, so `nix profile add nixpkgs#uv` is skipped and
a restored machine silently ends up on the older channel uv. This has been
done once already. The guard now tests `~/.nix-profile/bin/uv` rather than
`command -v uv` so that a future PATH entry cannot defeat it again.

`systemd.user.services.user-python-venv` needs no `systemPackages` entry
either -- `path = [ pkgs.uv ]` pulls the derivation in by store path. That is
also what makes the venv provision correctly at the very first login of a
restored machine, which happens after the reboot in RESTORE.md step 4 and
*before* `03-apply-home.sh` is run by hand in step 5.

**`nixpkgs#foo` means the *pinned* nixpkgs now, not unstable.** The flake
sets a system registry entry (`/etc/nix/registry.json`) mapping the bare
`nixpkgs` id to the revision in `flake.lock`, and points `NIX_PATH` at it.
That is the point — `nix shell nixpkgs#jq` and `<nixpkgs>` finally agree with
what the system was built from, which a channel could never guarantee. But it
silently changes what an ad-hoc `nix shell`/`nix run`/`nix profile add` gives
you, from whatever unstable served that minute to a fixed, older set. When
you genuinely want newer than the pin, spell the source out in full rather
than relying on the id; `scripts/03-apply-home.sh` does this for `uv`.

It also costs ~197 MiB per system generation, because the nixpkgs source has
to be in the closure for that to work. That is not new disk use so much as
moved: it used to sit in root's channel profile instead, outside any
generation and impossible to roll back with one.

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
