{ pkgs, ... }:

# LastPass CLI (`lpass`), built from upstream master rather than nixpkgs.
#
# nixpkgs ships 1.6.1, which pins LastPass's TLS public keys. LastPass moved
# lastpass.com to a new GlobalSign E46 chain on 2026-10-08, so every 1.6.1
# request fails with "SSL peer certificate or SSH remote key was not OK"
# (lastpass/lastpass-cli#740). 1.6.2 drops the pinning and verifies against
# the system CA store. Master is used over the 1.6.2 tag for AES-256-GCM
# vault support (#747, #750): items LastPass re-encrypts with GCM do not
# decrypt on 1.6.2. Drop this override once nixpkgs carries a release with
# both.
let
  lastpass-cli = pkgs.lastpass-cli.overrideAttrs (old: {
    version = "1.6.2-unstable-2026-11-19";
    src = pkgs.fetchFromGitHub {
      owner = "lastpass";
      repo = "lastpass-cli";
      rev = "949bad64e9db1bed89606cba78f32f6708cef3f0";
      hash = "sha256-U6tml+IqWMXfxmlqBbOleyldFCZSz1IMM1mFC7wYZmQ=";
    };
    # The nixpkgs patch only raises cmake_minimum_required; it does not apply
    # to master, so the policy floor is set directly instead. Ours fixes a
    # segfault: when the LastPass Authenticator (out-of-band) step ends in an
    # error, `login --trust` dereferenced the NULL session and crashed,
    # hiding LastPass's error message.
    patches = [ ./patches/lastpass-cli-oob-trust-null-session.patch ];
    cmakeFlags = (old.cmakeFlags or [ ]) ++ [ "-DCMAKE_POLICY_VERSION_MINIMUM=3.5" ];
  });
in
{
  environment.systemPackages = [ lastpass-cli ];
}
