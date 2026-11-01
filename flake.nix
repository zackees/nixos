{
  description = "nixos -- an AMD Ryzen 7 3700X workstation, declared in full";

  inputs = {
    # Pinned to the exact revision the nixos-26.05 channel was at when this
    # repo moved off channels, so that migration was a no-op and any later
    # difference is a deliberate `nix flake update` in the history rather
    # than whatever the channel happened to serve that day. That silent drift
    # is the whole reason flake.lock exists here; see issue #3.
    nixpkgs.url = "github:NixOS/nixpkgs/c5c4a43b0e8056328ec4529f735cabdb8f1942bb";

    # A second nixpkgs, used for ONE thing: the KDE package set. Plasma 6.7
    # is where per-screen virtual desktops landed (bug 107302, 21 years
    # open), and the 26.05 line stays on 6.6.x for its whole life. Pinned to
    # a revision rather than the branch for the same reason nixpkgs above is;
    # bump it on purpose. See issue #10 for the options that were weighed.
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/3ed67ec0a4d3c7ab4ae1f04f8ee8df07bfa506a2";

    # Was builtins.fetchTarball of release-26.05.tar.gz pinned by sha256.
    # `follows` keeps it on the same nixpkgs as the system, which the tarball
    # form could not express -- it silently used whatever <nixpkgs> resolved to.
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Tracks trunk rather than a release, as it did before: plasma-manager
    # cuts releases rarely and the panel options this config uses land on
    # trunk first. flake.lock is what makes that safe now.
    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };

    # Compile the wallpaper plugin against the same Qt/KDE as Plasma.
    kde-shader-wallpaper-src = {
      url = "github:y4my4my4m/kde-shader-wallpaper/d672455302ce7053bb7cc873b9e6225615063bef";
      flake = false;
    };

    # Hermes Agent -- the messaging gateway and dashboard this machine runs.
    # Previously installed ad-hoc with `nix profile install`, which left the
    # three hand-written systemd user units pointing at a /nix/store path that
    # nix-collect-garbage can delete. Declaring it here makes the package a
    # NixOS-managed dependency, so the units survive GC and rebuilds.
    #
    # Pinned to the exact revision that profile install had (0.21.0), so this
    # migration is a no-op rather than a silent upgrade -- same reasoning as
    # the nixpkgs pin above. Bump it deliberately, then restart the units.
    #
    # TEMPORARY: the pin carries one local fix on top of upstream 4ea8d23 --
    # BrowseShSource falls back to a catalog entry's own GitHub link when
    # browse.sh's detail endpoint has dropped it, which is why the dashboard's
    # skill Install button failed with "Stale index entry" for
    # browserbase.com/cookie-sync and 11 other skills that were moved to the
    # browserbase/skills repo. Upstream PR:
    # https://github.com/NousResearch/hermes-agent/pull/145678 -- once merged,
    # point this back at `github:NousResearch/hermes-agent/<merge commit>` and
    # drop the fork.
    #
    # Second local fix on top (branch nix/gpu-boot-ledger): the Linux GPU
    # launch ledger, so a force-kill or second-instance launch no longer pins
    # the desktop app to SwiftShader CPU rendering forever (~5 fps here, the
    # sticky marker never expired on a 0.0.0 build). talos-hq/hermes-slim#6.
    #
    # Branch nix/consent-tap-deploy = nix/browse-sh-fallback (which now carries
    # zackees/hermes-agent#3: a Telegram button tap writes
    # ~/.hermes/consent/<id>.approved for hermes-consent-exec, plus #2's
    # bounded gateway restarts) merged with nix/gpu-boot-ledger. The two had
    # diverged by one commit each, so pinning either alone dropped a fix.
    hermes-agent.url = "git+https://github.com/zackees/hermes-agent?ref=nix/consent-tap-deploy&rev=e7ab2444cdd687c5b1931fa7c1e1f42d56c91a97";

    # The private-desktop application tracks main (with its noVNC submodule);
    # flake.lock pins the exact revision, and scripts/apply.sh advances it.
    docker-vm = {
      url = "git+https://github.com/zackees/docker-vm?ref=main&submodules=1";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # talos-bar, the Python/Qt bar replacing the Plasma top panel, with the
    # Meta+Space search popup (feat/searchd until talos-hq/talos-bar#30 lands);
    # flake.lock pins the commit.
    talos-bar = {
      url = "git+https://github.com/talos-hq/talos-bar?ref=feat/searchd";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    # talos-vox, our voxtype fork (dictation, and the voice half of talos-bar's
    # search popup). Source only: system/configuration.nix builds it through
    # the nixpkgs voxtype derivation so the CUDA/ONNX setup there carries over.
    talos-vox = {
      url = "git+https://github.com/talos-hq/talos-vox?ref=feat/kernal-api-audio";
      flake = false;
    };

    # Consent-gated sudo for the Hermes agents: ONE sudoers rule naming ONE
    # helper, and the helper refuses unless the maintainer approved the exact
    # argv in Telegram (single use, TTL, audit log). Pinned to the same
    # revision the module was tested at, not to main -- same rule as the
    # inputs above. Bump deliberately and re-run the VM check.
    client-skills = {
      url = "github:talos-hq/client-skills/afa4c57ba336a75a29b64158b6fb052cfeb8a136";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, ... }@inputs: {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";

      # configuration.nix reaches plasma-manager through this.
      specialArgs = { inherit inputs; };

      modules = [
        ./system/configuration.nix
        ./system/talos-bar.nix
        inputs.client-skills.nixosModules.consent-sudo
        home-manager.nixosModules.home-manager
      ];
    };
  };
}
