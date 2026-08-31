# What is not in this repo, and why

A restore is only trustworthy if the gaps are written down. These are the
things this repository deliberately does not carry, each with the reason and
the one command that fixes it.

## Credentials that rotate

### GitHub token

Stored in KDE Wallet (`~/.local/share/kwalletd/kdewallet.kwl`), which `gh`
uses as its keyring. Not committed.

The reason is structural rather than cautious: this repository is private, so
you need a GitHub credential *before* you can clone it. A token stored inside
could never be the one that got you in. It would also go stale — the current
one is a `gho_` OAuth token from `gh auth login`, and revoking or re-issuing
it is routine.

    gh auth login          # HTTPS; paste a token or use the browser flow

Scopes on the current token: `gist`, `read:org`, `repo`, `workflow`.

### Anthropic / Claude

`~/.claude/.credentials.json` holds an OAuth token with an expiry. Committing
a credential that expires would give a restore a file that looks right and
fails anyway.

    claude                 # first run opens a browser to sign in

## Credentials that do not exist on this machine

Listed so a restore does not go hunting for them.

- **Wi-Fi.** `/etc/NetworkManager/system-connections/` is empty. The machine
  is on wired ethernet. Nothing to restore.
- **SSH.** No host keys under `/etc/ssh` (`services.openssh` is disabled) and
  no `~/.ssh` at all. Git talks to GitHub over HTTPS. If you later enable
  SSH, host keys are generated on first boot and should stay out of git —
  reach for `sops-nix` or `agenix` at that point.
- **GPG.** No keyring.

## Passwords

Not in this repo. Nothing in it is a credential, and `scripts/sync.sh`
enforces that by scanning captured files before every push.

Carrying the `/etc/shadow` hashes would make a restore fully unattended, and
an earlier version of this repo did exactly that. It was removed on purpose.
A yescrypt hash is offline-crackable, so committing one makes the repository's
privacy load-bearing: a single accidental exposure, or one added collaborator,
would mean rotating both passwords *and* rewriting history, because the hash
lives on in old commits. Buying unattendedness with that liability is a bad
trade when the alternative costs one prompt.

So passwords are set at install time instead:

    scripts/02-install.sh        prompts for root, then for niteris

`users.mutableUsers` is left at its default `true`, so `passwd` is the only
thing that ever sets a password on this machine. `configuration.nix` sets no
`hashedPassword` for any account.

If you later decide you want unattended restores back, the right tool is
`sops-nix` or `agenix` — the hashes get encrypted to an age key that lives
outside the repo, so the repo stays safe even if it leaks. Do not just put
them back in a `.nix` file.

## Data, not configuration

Out of scope by design. Back these up separately; a config repo is the wrong
tool for them.

- `~/Documents`, `~/Pictures`, `~/Downloads`, `~/Projects`
- Brave (`~/.config/BraveSoftware`) and Firefox (`~/.config/mozilla`)
  profiles: history, bookmarks, extensions, saved logins
- `~/.bash_history`
- `~/.claude/` beyond `settings.json` — session transcripts, project history
- `~/.clud/` beyond `settings.json` — `data.redb`, caches, tool state
- The second physical disk (`sda`, 931G of NTFS — a Windows installation).
  No script in this repo touches it, including `01-partition.sh`.

## State that is captured but drifts

Everything under `home/kde/` is a snapshot of files KDE rewrites at runtime.
There is no declarative source for most of them, so they are copied verbatim
and go stale as soon as you change a setting in System Settings.

`scripts/capture.sh` pulls them back in. Run it after any deliberate KDE
change you want to keep.

The Plasma **panel** is the exception — it is declared properly, via
plasma-manager, in `system/configuration.nix`. Note that plasma-manager
replaces panels wholesale, so the widget list there is the whole panel.

## Known rough edges

- **`plasma-manager` is pinned to `trunk`**, not a release. Its tarball hash
  is pinned so builds stay reproducible, but bumping it can bring API changes
  along with the fix you wanted.
- **The `Meta+H` dictation binding is imperative.** It works by way of a
  `.desktop` entry in `~/.local/share/applications/` plus an entry in the
  captured `kglobalshortcutsrc`. plasma-manager's `hotkeys.commands` could
  declare this properly in `configuration.nix` and drop both files. Worth
  doing; not done, because the current setup works and was left alone.
- **`kwinoutputconfig.json` matches displays by EDID hash.** Replace a
  monitor and the captured layout will not apply to it.
