# Dell VxRail build server

`dell-fsx3mn2` is the VxRail E560F (service tag FSX3MN2), separate from the
`nixos` desktop. Build this host with:

```bash
nixos-rebuild build --flake .#dell-fsx3mn2
```

Never activate `.#nixos` on this server or the Dell output on the desktop.
The hardware module was generated on the Dell after installing the Silicon
Power 1 TB NVMe SSD, serial AA253710262. Its GPT layout is a 1 GiB EFI system
partition, 32 GiB swap, and the remaining space as ext4 root. Boot is UEFI.

## Boot status

NixOS runs from the NVMe root, but BIOS 1.4.5 currently marks both the
systemd-boot and GRUB entries on this retail SSD unavailable. The configured
GRUB removable EFI loader is installed on its ESP; standalone disk boot has
not passed. A temporary iDRAC virtual CD supplies the installed kernel and
initrd. Keep the active system generation and bootstrap media available until
a standalone boot path is verified. The bootstrap image must be regenerated
when changing the kernel, initrd, or system generation.

Do not treat a successful build or an online runner as proof of reboot
readiness. Do not flash generic PowerEdge firmware onto the VxRail without
verifying the exact supported package and upgrade sequence.

SSH permits only `root` and `niteris`, using public keys provisioned outside
this repository in their home directories. `niteris` has administrative sudo
and Docker access. iDRAC credentials remain in the administrator workstation's
keystore; they are not available to the runner or stored in this checkout.

## GitHub runner

The NixOS host owns Docker and the `obs-rust-runner` systemd service. The
runner itself uses Ubuntu 26.04 because obs-rust's existing Linux CI installs
Ubuntu packages with apt. `runner/Dockerfile` pins the Ubuntu image digest,
Actions runner release/checksum, and uv release/checksum. Update these pins
deliberately; GitHub requires sufficiently current runners, so a pinned runner
needs regular maintenance rather than unattended binary updates.

The `Dell-NixOS` organization runner group should allow only the selected
`obs-rust/obs-studio` repository and trusted workflow refs. Registration uses
an expiring organization registration token, not an organization PAT. Provision
it as a root-only file at
`/var/lib/obs-runner-secrets/registration-token`, then start the service:

```bash
sudo systemctl start obs-rust-runner
sudo systemctl status obs-rust-runner
sudo journalctl -u obs-rust-runner
```

The unit stays inactive until a registration token or an existing runner
identity is present. Existing identity survives restarts in
`/var/lib/obs-runner/agent`; a new token is needed only when re-registering.
Never put a token in Nix expressions, environment examples, git, or command
arguments. The entrypoint supplies the token through the official runner's
configuration-only environment input and unsets it before accepting jobs.

Labels are `self-hosted`, `Linux`, `X64`, `nixos-host`, `obs-ubuntu-2604`, and
`dell-fsx3mn2`. The host does not impersonate `ubuntu-latest` or `ubuntu-26.04`.
This configuration does not change repository workflow routing or set
`MQ_RUNNER_LABELS`; validate the exact workflow/ref policy before routing
merge-queue jobs here.

Workspace, home, uv binaries, and tool cache all live below
`/var/lib/obs-runner`, mounted at the identical absolute path inside the
container. Sibling Docker builds resolve mount sources on the host, so this
path identity is necessary for obs-rust's Docker-based validation scripts.

Docker socket access grants effective host administrator access; the Ubuntu
container provides build compatibility, not isolation from untrusted jobs.
Keep administration keys and long-lived GitHub credentials off this runner.
