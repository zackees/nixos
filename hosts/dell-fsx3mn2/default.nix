{ lib, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./runner.nix
  ];

  networking.hostName = "dell-fsx3mn2";
  networking.useDHCP = true;
  networking.firewall.allowedTCPPorts = [ 22 ];
  time.timeZone = "America/Los_Angeles";

  boot.loader.grub = {
    enable = true;
    device = "nodev";
    efiSupport = true;
    efiInstallAsRemovable = true;
    copyKernels = true;
    configurationLimit = 5;
  };
  boot.loader.efi.canTouchEfiVariables = false;
  fileSystems."/boot".options = lib.mkForce [ "fmask=0077" "dmask=0077" ];
  boot.tmp.cleanOnBoot = true;
  hardware.cpu.intel.updateMicrocode = true;
  hardware.enableRedistributableFirmware = true;
  services.fstrim.enable = true;
  services.irqbalance.enable = true;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
      AllowUsers = [ "root" "niteris" ];
    };
  };
  # Authorized public keys are provisioned into the users' home directories;
  # no credentials or workstation-specific keys enter this repository/store.
  users.users.niteris = {
    isNormalUser = true;
    uid = 1000;
    extraGroups = [ "wheel" "docker" ];
  };
  security.sudo.wheelNeedsPassword = false;

  virtualisation.docker.enable = true;
  programs.nix-ld.enable = true;
  environment.systemPackages = with pkgs; [
    git
    gh
    curl
    jq
    uv
    tmux
    htop
    pciutils
    usbutils
    nvme-cli
    smartmontools
    lm_sensors
    ethtool
    docker-buildx
  ];

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    max-jobs = 4;
    cores = 8;
    auto-optimise-store = true;
  };
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  system.stateVersion = "26.05";
}
