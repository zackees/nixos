{ pkgs, ... }:

# LastPass CLI (`lpass`), built from our fork talos-hq/lastpass-cli rather
# than nixpkgs.
#
# - nixpkgs ships 1.6.1, which pins LastPass's TLS public keys. LastPass moved
#   lastpass.com to a new GlobalSign E46 chain on 2026-10-08, so every 1.6.1
#   request fails with "SSL peer certificate or SSH remote key was not OK"
#   (lastpass/lastpass-cli#740). 1.6.2 drops the pinning.
# - Upstream master adds AES-256-GCM vault support (#747, #750).
# - The fork adds talos-hq/lastpass-cli#1: this account's primary second
#   factor is a FIDO2 key, which lpass cannot use, and upstream's login then
#   fails at once with "Multifactor authentication failed!" (#719). The fork
#   falls back to a Google Authenticator code (LPASS_MFA_PROVIDER picks the
#   provider), and fixes a segfault in `login --trust`.
#
# Drop this override once nixpkgs carries a release with all three.
let
  lastpass-cli = pkgs.lastpass-cli.overrideAttrs (old: {
    version = "1.6.2-unstable-2026-11-22";
    src = pkgs.fetchFromGitHub {
      owner = "talos-hq";
      repo = "lastpass-cli";
      rev = "582a4a395067ae2e0dd40dcdebf57259e90fc2f5";
      hash = "sha256-MUUWm/gV0dyg/KmyRcXsKl3lUqblyBwuTAh3O2axUP4=";
    };
    # The nixpkgs patch only raises cmake_minimum_required and does not apply
    # to this tree; set the policy floor directly instead.
    patches = [ ];
    cmakeFlags = (old.cmakeFlags or [ ]) ++ [ "-DCMAKE_POLICY_VERSION_MINIMUM=3.5" ];
  });
in
{
  environment.systemPackages = [ lastpass-cli ];
}
