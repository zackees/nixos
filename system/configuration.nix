# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).

{ config, pkgs, lib, ... }:
let
  # TMOG (https://tmog.org) is a third-party Qt 6 task manager shipped only as an
  # unsigned AppImage, so there is no nixpkgs attribute for it. wrapType2 runs it
  # in an FHS sandbox where its bundled Qt libs resolve. The .deb upstream also
  # offers is unusable here (no dpkg) and the .tar.gz ships no Qt of its own.
  # Pinned by hash: bump url and hash together when the beta updates.
  tmogVersion = "0.1.1";

  tmogSrc = pkgs.fetchurl {
    url = "https://tmog.org/downloads/TMOG-Task-Manager-Linux-x86_64.AppImage";
    hash = "sha256-C68GRpfWdzKADWMVZEaX7BU7jlBqUXMwTIXzMLLb5tI=";
  };

  # Same AppImage, unpacked, so the Plasma launcher can reuse the upstream
  # desktop entry and icon rather than us hand-writing them.
  tmogExtracted = pkgs.appimageTools.extract {
    pname = "tmog-task-manager";
    version = tmogVersion;
    src = tmogSrc;
  };

  tmog = pkgs.appimageTools.wrapType2 {
    pname = "tmog-task-manager";
    version = tmogVersion;
    src = tmogSrc;
    extraInstallCommands = ''
      install -Dm444 ${tmogExtracted}/com.tmog.taskmanager.desktop \
        $out/share/applications/com.tmog.taskmanager.desktop
      install -Dm444 ${tmogExtracted}/usr/share/icons/hicolor/512x512/apps/tmog-task-manager.png \
        $out/share/icons/hicolor/512x512/apps/tmog-task-manager.png
    '';
  };

  # ── Declarative Plasma (home-manager + plasma-manager) ──
  # NixOS manages SYSTEM state, but Plasma panels are USER state, which plain
  # configuration.nix cannot reach. home-manager supplies that layer and
  # plasma-manager declares the panel on top of it. Both pinned by hash so the
  # desktop layout is reproducible; bump url and sha256 together to update.
  homeManagerSrc = builtins.fetchTarball {
    url = "https://github.com/nix-community/home-manager/archive/release-26.05.tar.gz";
    sha256 = "1qsx6l8z2v2rzr47chfqvmr9585lcrb2wihixbklmz63nhsba6sb";
  };

  plasmaManagerSrc = builtins.fetchTarball {
    url = "https://github.com/nix-community/plasma-manager/archive/trunk.tar.gz";
    sha256 = "1m45385zs1bm1f6ligs2r00q4r9zaqr4rp0wggvvfwrh629mk64d";
  };
in
{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      "${homeManagerSrc}/nixos"
    ];

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "nixos"; # Define your hostname.
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Enable networking
  networking.networkmanager.enable = true;

  # Set your time zone.
  time.timeZone = "America/Los_Angeles";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_US.UTF-8";
    LC_IDENTIFICATION = "en_US.UTF-8";
    LC_MEASUREMENT = "en_US.UTF-8";
    LC_MONETARY = "en_US.UTF-8";
    LC_NAME = "en_US.UTF-8";
    LC_NUMERIC = "en_US.UTF-8";
    LC_PAPER = "en_US.UTF-8";
    LC_TELEPHONE = "en_US.UTF-8";
    LC_TIME = "en_US.UTF-8";
  };

  # Enable the X11 windowing system.
  # You can disable this if you're only using the Wayland session.
  services.xserver.enable = true;

  # Enable the KDE Plasma Desktop Environment.
  services.displayManager.sddm.enable = true;
  services.desktopManager.plasma6.enable = true;

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  # Enable CUPS to print documents.
  services.printing.enable = true;

  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # If you want to use JACK applications, uncomment this
    #jack.enable = true;

    # Use the WirePlumber session manager
    #wireplumber.enable = true;
  };

  environment.systemPackages = with pkgs; [
    tmog                # tmog.org AppImage; see let-block above
    python3
    python3Packages.pip
    brave
    gh
    kitty
    imagemagick

    # ── CLI toolkit (modelled on Omarchy's base package set) ──
    ripgrep             # rg: fast recursive search
    fd                  # find replacement; also fzf's file source
    bat                 # cat with syntax highlighting + line numbers
    eza                 # ls replacement, icons + git status
    jq                  # JSON on the command line
    wl-clipboard        # wl-copy / wl-paste, required on Wayland
    lazygit             # TUI git
    btop                # resource monitor
    dua                 # interactive disk usage explorer
    tealdeer            # tldr: practical examples instead of man pages
    gum                 # shell-script UI widgets
    neovim              # installed, but nano stays $EDITOR (see below)

    # ── System administration ──
    inxi                # one-shot hardware/system report
    socat               # socket plumbing
    whois
    inetutils           # telnet, ftp, hostname, ping variants
    kdePackages.ksshaskpass  # graphical password prompt for sudo -A / ssh
    voxtype             # push-to-talk voice-to-text (Meta+H)
    pciutils            # lspci; voxtype's GPU probe needs it to name the card

    alsa-utils          # amixer/aplay/arecord
    alsa-scarlett-gui   # 48V, gain, air, pad, direct monitor for the 2i2
  ];

  # nano is already installed and enabled by default on NixOS; make it the
  # editor every tool reaches for. neovim is available as `nvim` when wanted.
  environment.variables = {
    EDITOR = "nano";
    VISUAL = "nano";
  };

  # fzf: the module installs pkgs.fzf and sources the bash integration,
  # giving ctrl+r fuzzy history, ctrl+t file picker and alt+c directory jump.
  programs.fzf = {
    keybindings = true;
    fuzzyCompletion = true;
  };

  # zoxide replaces cd with a frecency-ranked version; plain `cd <realdir>`
  # still behaves normally, `cd <fragment>` jumps to a known directory.
  programs.zoxide = {
    enable = true;
    enableBashIntegration = false;  # done below, ordering matters
    flags = [ "--cmd cd" ];
  };

  # zoxide tracks directories via PROMPT_COMMAND, and starship's init
  # replaces PROMPT_COMMAND wholesale. The module's own integration runs
  # before starship, so its hook gets clobbered and the database never
  # learns. promptPluginInit renders after promptInit, so init it here.
  programs.bash.promptPluginInit = lib.mkAfter ''
    eval "$(${config.programs.zoxide.package}/bin/zoxide init bash --cmd cd)"
  '';

  programs.starship.enable = true;   # prompt: git state, exit codes, versions
  programs.direnv.enable = true;     # per-project envs via .envrc / shell.nix
  programs.tmux.enable = true;       # session persistence across SSH drops
  programs.bash.completion.enable = true;
  services.locate.enable = true;     # plocate by default; nightly db update

  # Shorthands, adapted from Omarchy's default/bash/aliases.
  environment.shellAliases = {
    ".." = "cd ..";
    "..." = "cd ../..";
    "...." = "cd ../../..";

    ls = "eza -lh --group-directories-first --icons=auto";
    lsa = "eza -lah --group-directories-first --icons=auto";
    lt = "eza --tree --level=2 --long --icons --git";
    lta = "eza --tree --level=2 --long --icons --git -a";

    g = "git";
    gst = "git status";
    gcm = "git commit -m";
    gcam = "git commit -a -m";
    gcad = "git commit -a --amend";
    lg = "lazygit";

    t = "tmux attach || tmux new -s Work";

    # fuzzy file picker with previews; images render inline via kitty icat
    ff = "fzf --preview 'case $(file --mime-type -b {}) in image/*) kitty icat --clear --transfer-mode=memory --stdin=no --place=\${FZF_PREVIEW_COLUMNS}x\${FZF_PREVIEW_LINES}@0x0 {} ;; *) bat --style=numbers --color=always {} ;; esac'";
    eff = "$EDITOR \"$(ff)\"";
  };

  # Stock nixpkgs voxtype omits the OSD, and any GPU backend with it.
  # voxtype's Cargo.toml declares `default = []` and the nixpkgs package
  # passes no features at all, so the stock build has neither an OSD
  # frontend for voxtype-osd to launch nor a Whisper GPU backend -- every
  # feature this machine wants has to be named here.
  #
  # NOTE: buildRustPackage converts `buildFeatures` into `cargoBuildFeatures`
  # when the function is applied, so overrideAttrs must set the latter.
  # Setting buildFeatures here is silently ignored and yields an identical
  # binary.
  nixpkgs.overlays = [
    (final: prev: {
      voxtype = prev.voxtype.overrideAttrs (old: {
        cargoBuildFeatures = (old.cargoBuildFeatures or [ ]) ++ [ "osd-gtk4" ];
        cargoCheckFeatures = (old.cargoCheckFeatures or [ ]) ++ [ "osd-gtk4" ];
        buildInputs = (old.buildInputs or [ ]) ++ (with prev; [
          gtk4
          gtk4-layer-shell
          cairo
          glib
        ]);
      });
    })
  ];

  # ── Graphics ────────────────────────────────────────────────
  # The card is a GA106 (RTX 3060) and was running on nouveau, which is why
  # the desktop felt sluggish: nouveau has no reclocking for Ampere, so the
  # GPU sits at its lowest power state no matter the load. The proprietary
  # driver fixes that, and is also the only way to get CUDA for whisper.
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.graphics.enable = true;

  hardware.nvidia = {
    # Required for Wayland. KWin will not start on NVIDIA without KMS, and
    # this is also what lets the driver hand off the console at boot.
    modesetting.enable = true;

    # open = true is not optional here. NVIDIA dropped the closed kernel
    # module for Turing and newer, and 595 ships only the open one for this
    # card; the "open" in the name is the KERNEL MODULE, not the userspace
    # driver, which stays proprietary either way.
    open = true;

    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;

    # Desktop, not a laptop: no hybrid graphics to suspend, and the runtime
    # power management is a known source of wake-up hangs on desktops.
    powerManagement.enable = false;
  };

  # ── Dictation ────────────────────────────────────────────────
  # voxtype transcribes speech and types it at the cursor. It defaults to
  # wtype, which needs the zwp_virtual_keyboard_manager_v1 Wayland protocol
  # that KWin does not implement (verified: wtype exits with "Compositor
  # does not support the virtual keyboard protocol"). ydotool goes through
  # /dev/uinput instead, so it is compositor-independent and works on KDE.
  programs.ydotool.enable = true;

  # Run the voxtype daemon for the graphical session; Meta+H (a KDE global
  # shortcut) calls `voxtype record toggle`, which signals this daemon.
  systemd.user.services.voxtype = {
    description = "voxtype dictation daemon";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" "ydotoold.service" ];

    # environment.variables only reaches login shells, not systemd user
    # services, so the daemon needs ydotool on PATH and the socket path
    # given explicitly - otherwise typing silently degrades to clipboard.
    # voxtype itself must be on PATH too: the daemon launches the on-screen
    # display by spawning bare `voxtype-osd`, so a PATH without its own
    # package yields "Failed to spawn `voxtype-osd`: No such file or
    # directory" and dictation runs blind.
    path = [ pkgs.voxtype pkgs.ydotool pkgs.wl-clipboard ];
    environment.YDOTOOL_SOCKET = config.environment.variables.YDOTOOL_SOCKET;

    # voxtype refuses to start when another instance holds the lock in
    # /run/user/1000/voxtype, and exits 1 every time. Without a start limit
    # that is an unbounded 2-second respawn loop rather than a visible
    # failure - it ran to 64 restarts before anyone noticed. These are
    # [Unit] keys, not [Service] ones, so they cannot go in serviceConfig.
    startLimitIntervalSec = 60;
    startLimitBurst = 5;

    serviceConfig = {
      ExecStart = "${pkgs.voxtype}/bin/voxtype daemon";
      Restart = "on-failure";
      RestartSec = 2;
    };
  };

  programs.git = {
    enable = true;
    config = {
      user.name = "Zach Vorhies";
      user.email = "zachvorhies@protonmail.com";
    };
  };

  # ── Privilege escalation ─────────────────────────────────────
  # One successful authentication unlocks sudo for every session, including
  # ones with no controlling TTY, for 15 minutes.
  # Drop it early at any time with `sudo -k`. timestamp_timeout is in
  # minutes; remove timestamp_type=global to scope the ticket per-terminal
  # instead of machine-wide.
  #
  security.sudo.extraConfig = ''
    Defaults timestamp_type=global
    Defaults timestamp_timeout=15
  '';

  # Graphical KDE password dialog. askpass is a sudo.conf setting, NOT a
  # sudoers Defaults entry - putting it in sudoers fails `visudo -c` with
  # "unknown defaults entry". sudo uses it automatically when there is no
  # terminal to prompt in, and on demand with `sudo -A`. NixOS does not
  # manage /etc/sudo.conf, and unset values keep their built-in defaults.
  # For GUI apps, polkit's pkexec already pops a dialog via the
  # polkit-kde-authentication-agent that Plasma runs.
  environment.etc."sudo.conf".text =
    "Path askpass ${pkgs.kdePackages.ksshaskpass}/bin/ksshaskpass\n";

  environment.variables.SUDO_ASKPASS =
    "${pkgs.kdePackages.ksshaskpass}/bin/ksshaskpass";

  # Route interactive sudo through the graphical prompt too. Guarded on a
  # graphical session being present: on a bare console or over SSH there is
  # nowhere to draw a dialog, so sudo must fall back to prompting inline.
  # Aliases apply to interactive shells only, so scripts are unaffected.
  programs.bash.interactiveShellInit = ''
    if [ -n "''${WAYLAND_DISPLAY:-}''${DISPLAY:-}" ]; then
      alias sudo='sudo -A'
    fi
  '';

  # nix-ld provides /lib64/ld-linux-x86-64.so.2 so non-Nix ELF binaries
  # (e.g. the `clud` entrypoint installed by uv) can find their loader.
  programs.nix-ld.enable = true;

  # Put uv tool shims (~/.local/bin) on PATH for every session, not just
  # interactive bash via ~/.bashrc. Merged with the default PATH entries.
  environment.sessionVariables.PATH = [ "$HOME/.local/bin" ];

  fonts = {
    packages = with pkgs; [
      inter
      jetbrains-mono
      nerd-fonts.jetbrains-mono # Omarchy's default: JetBrainsMono Nerd Font
      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-color-emoji
      liberation_ttf
    ];

    fontconfig = {
      defaultFonts = {
        sansSerif = [ "Inter" "Noto Sans" ];
        serif = [ "Noto Serif" ];
        monospace = [ "JetBrainsMono Nerd Font" "Noto Sans Mono" ];
        emoji = [ "Noto Color Emoji" ];
      };
      # NixOS ships subpixel rendering off (10-sub-pixel-none.conf). Turning it
      # on plus slight hinting is the single biggest win for text crispness on
      # a normal LCD panel.
      hinting.style = "slight";
      subpixel.rgba = "rgb";

      # jetbrains-mono ships .otf, .ttf and .woff2, and fontconfig otherwise
      # resolves `monospace` to the web-only .woff2. Reject that directory so
      # the real outline files win.
      localConf = ''
        <?xml version="1.0"?>
        <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
        <fontconfig>
          <selectfont><rejectfont><glob>*/WOFF2/*</glob></rejectfont></selectfont>
        </fontconfig>
      '';
    };
  };

  # Enable touchpad support (enabled default in most desktopManager).
  # services.libinput.enable = true;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users."niteris" = {
    isNormalUser = true;
    description = "ZachVorhies";
    # "input" is what makes hold-to-talk possible: voxtype reads key press
    # AND release straight off /dev/input/event* (root:input 0660), because
    # KGlobalAccel only ever fires on press. It also unlocks voxtype's
    # modifier-release guard, which holds typing back until Meta is actually
    # up - otherwise text typed while the key is still down arrives at the
    # compositor as Meta+<letter> and triggers shortcuts instead.
    extraGroups = [ "networkmanager" "wheel" "ydotool" "input" ];
    packages = with pkgs; [
      kdePackages.kate
    #  thunderbird
    ];
  };

  # Install firefox.
  programs.firefox.enable = true;

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # List packages installed in system profile.
  # You can use https://search.nixos.org/ to find more packages (and options).
  # environment.systemPackages = with pkgs; [
  #   vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
  #   wget
  # ];

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  # services.openssh.enable = true;

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # Copy the NixOS configuration file and link it from the resulting system
  # (/run/current-system/configuration.nix). This is useful in case you
  # accidentally delete configuration.nix.
  # system.copySystemConfiguration = true;

  # ── Declarative Plasma panel ──
  # plasma-manager REPLACES panels wholesale rather than merging, so this list
  # IS the panel: anything omitted here disappears at next login. Order matches
  # the old imperative AppletOrder 5;6;7;8;28;29;30;31;27;9;22;23.
  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.backupFileExtension = "hm-bak";
  home-manager.users.niteris =
    { ... }:
    {
      imports = [ "${plasmaManagerSrc}/modules" ];
      home.stateVersion = "26.05";

      programs.plasma = {
        enable = true;

        panels = [
          {
            location = "bottom";
            widgets = [
              "org.kde.plasma.kickoff"
              "org.kde.plasma.pager"
              {
                name = "org.kde.plasma.icontasks";
                config.General.launchers =
                  "applications:systemsettings.desktop,preferred://filemanager,preferred://browser,applications:kitty.desktop";
              }
              "org.kde.plasma.marginsseparator"

              # The glanceable strip: all 16 cores, memory, disk fill.
              "org.kde.plasma.systemmonitor.cpucore"
              "org.kde.plasma.systemmonitor.memory"
              "org.kde.plasma.systemmonitor.diskusage"

              # Click-through to TMOG for the deep dive.
              {
                name = "org.kde.plasma.icon";
                config.General.url =
                  "file:///run/current-system/sw/share/applications/com.tmog.taskmanager.desktop";
              }
              {
                name = "org.kde.plasma.icon";
                config.General.url =
                  "file:///run/current-system/sw/share/applications/kcm_kscreen.desktop";
              }

              "org.kde.plasma.systemtray"
              "org.kde.plasma.digitalclock"
              "org.kde.plasma.showdesktop"
            ];
          }
        ];
      };
    };

  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are pulled from,
  # so changing it will NOT upgrade your system - see https://nixos.org/manual/nixos/stable/#sec-upgrading for how
  # to actually do that.
  #
  # This value being lower than the current NixOS release does NOT mean your system is
  # out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "26.05"; # Did you read the comment?

}
