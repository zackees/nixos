{ pkgs, inputs, ... }:
{
  # Let any process attach to any other process of the same user: gdb -p,
  # strace -p and py-spy all work without sudo.
  #
  # The NixOS default, kernel.yama.ptrace_scope = 1, only lets a process
  # trace its own children. Every live diagnosis here needed root because of
  # that: py-spy on kitty's main thread (CLAUDE.md, "Measure the main
  # thread"), and gdb on a hung Telegram, where the sudo prompt went
  # unanswered and the stack was never captured.
  #
  # The cost, accepted deliberately on 2026-11-21: any program running as
  # this user can read the memory of every other process of this user (a
  # browser's, the password manager's). Root-owned processes and other users'
  # processes stay out of reach, as with classic Unix ptrace rules.
  boot.kernel.sysctl."kernel.yama.ptrace_scope" = 0;

  # From nixpkgs-unstable: the pinned 0.4.0 predates Python 3.14, which
  # kitty embeds, and failed with "Failed to find python version from
  # target process". 0.4.2 reads it.
  environment.systemPackages = [
    inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.py-spy
  ];
}
