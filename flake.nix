{
  description = "nixos -- an AMD Ryzen 7 3700X workstation, declared in full";

  inputs = {
    # Pinned to the exact revision the nixos-26.05 channel was at when this
    # repo moved off channels, so that migration was a no-op and any later
    # difference is a deliberate `nix flake update` in the history rather
    # than whatever the channel happened to serve that day. That silent drift
    # is the whole reason flake.lock exists here; see issue #3.
    nixpkgs.url = "github:NixOS/nixpkgs/c5c4a43b0e8056328ec4529f735cabdb8f1942bb";

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
  };

  outputs = { self, nixpkgs, home-manager, ... }@inputs: {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";

      # configuration.nix reaches plasma-manager through this.
      specialArgs = { inherit inputs; };

      modules = [
        ./system/configuration.nix
        home-manager.nixosModules.home-manager
      ];
    };
  };
}
