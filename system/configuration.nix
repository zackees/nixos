# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).

{ config, pkgs, lib, inputs, ... }:
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

  # ── A "Docker" launcher for the dock ──
  # Docker ships no GUI of its own -- the engine is a daemon, and the window
  # people call "Docker" is Docker Desktop, which does not exist here. So the
  # dock icon has to be built. It fronts lazydocker, a TUI covering the same
  # ground Desktop's dashboard does: containers, images, volumes, logs, stats.
  #
  # podman-desktop is still installed and is the richer GUI, but it is filed
  # under a name that gives no hint it drives Docker, which is exactly the
  # confusion this entry exists to fix.
  dockerIcon = pkgs.writeTextFile {
    name = "docker-tui-icon";
    destination = "/share/icons/hicolor/scalable/apps/docker-tui.svg";
    # Drawn here rather than pulled from a theme: no icon set on this machine
    # carries a docker or even a generic container glyph (checked breeze,
    # breeze-dark and hicolor), and utilities-terminal would defeat the whole
    # point of making it recognisable at a glance. Deliberately chunky --
    # it renders at 22px in the panel, where thin detail turns to mud.
    text = ''
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
        <g fill="#2496ed">
          <rect x="14" y="19" width="6" height="6" rx="1"/>
          <rect x="21" y="19" width="6" height="6" rx="1"/>
          <rect x="28" y="19" width="6" height="6" rx="1"/>
          <rect x="14" y="12" width="6" height="6" rx="1"/>
          <rect x="21" y="12" width="6" height="6" rx="1"/>
          <rect x="21" y="5" width="6" height="6" rx="1"/>
          <path d="M3 27h37c0 7-5 12-13 12H15C8 39 3 34 3 28z"/>
          <path d="M40 22c2-2 5-2 6 1-1 3-4 4-6 2z"/>
        </g>
      </svg>
    '';
  };

  dockerTui = pkgs.makeDesktopItem {
    name = "docker-tui";
    desktopName = "Docker";
    genericName = "Container manager";
    comment = "Containers, images, volumes and logs";
    # --class is what makes the running window group under this launcher
    # instead of appearing as a second, unrelated kitty task.
    exec = "kitty --class docker-tui -e lazydocker";
    icon = "docker-tui";
    categories = [ "Development" "System" ];
    terminal = false;
    startupWMClass = "docker-tui";
  };

  # ── The dock's launcher strip ──
  # quicklaunch takes fully-qualified file:// URLs, NOT the `applications:`
  # form the task manager accepts, and NOT preferred:// either. Given an
  # `applications:` URL it still creates the entries -- it just cannot resolve
  # any of them, so you get the right number of blank placeholder icons.
  # Verified both ways against a live widget before this was written.
  #
  # That is also why preferred://filemanager had to become Dolphin by name:
  # there is no scheme here that expands to a default application.
  dockLaunchers = map (d: "file:///run/current-system/sw/share/applications/${d}") [
    "systemsettings.desktop"
    "org.kde.dolphin.desktop"
    "brave-browser.desktop"
    "org.telegram.desktop.desktop"
    "signal.desktop"
    "kitty.desktop"
    "sublime_text.desktop"
    "org.kde.kdenlive.desktop"
    "fr.handbrake.ghb.desktop"
    "com.obsproject.Studio.desktop"
    "docker-tui.desktop"
    "podman-desktop.desktop"
    "com.feaneron.Boatswain.desktop"
  ];

  # ── The user's writable Python ──
  # Pinned here because this version number has to appear in three places
  # that must never drift apart: the uv download, the venv built from it,
  # and pipx's default interpreter. See the sessionVariables and the
  # user-python-venv unit further down for what it is all for.
  userPythonVersion = "3.13";
  userPythonHome =
    "$HOME/.local/share/uv/python/cpython-${userPythonVersion}-linux-x86_64-gnu";
  # boatswain has no NixOS module, so the autostart item that
  # programs.streamdeck-ui would have provided has to be made by hand.
  # Without it the deck stays dark until someone launches the app.
  # A desktop entry for ChatGPT, so the Stream Deck has an application to
  # launch rather than a URL to shell out to. Boatswain's action for this is
  # "launch application", which takes a .desktop entry -- giving it one keeps
  # the button's target declared here instead of typed into the GUI.
  #
  # Brave by name rather than xdg-open: the dock already pins Brave outright
  # for the same reason, that preferred:// and mimetype defaults resolve
  # unpredictably with two browsers installed.
  # Drawn here for the same reason dockerIcon is: no icon theme on this
  # machine carries anything for ChatGPT, and the alternatives are worse. A
  # generic globe says nothing on a 32-key deck where every key is a glyph,
  # and fetchurl'ing the real mark would put a remote asset and a hash in the
  # build for a decoration. This is an approximation, not the official logo --
  # the hexagonal lattice and the brand green, which is what actually has to
  # be recognisable at 96px on a key and 22px in the dock.
  chatgptIcon = pkgs.writeTextFile {
    name = "chatgpt-web-icon";
    destination = "/share/icons/hicolor/scalable/apps/chatgpt-web.svg";
    text = ''
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
        <g fill="none" stroke="#10a37f" stroke-width="3.6"
           stroke-linecap="round" stroke-linejoin="round">
          <path d="M24 6 L37.9 14 L37.9 30 L24 38 L10.1 30 L10.1 14 Z"/>
          <path d="M24 6 L24 22 L37.9 30"/>
          <path d="M10.1 14 L24 22 L24 38"/>
        </g>
      </svg>
    '';
  };

  chatgptLauncher = pkgs.makeDesktopItem {
    name = "chatgpt-web";
    desktopName = "ChatGPT";
    comment = "chat.openai.com";
    exec = "brave https://chat.openai.com";
    icon = "chatgpt-web";
    categories = [ "Network" ];
    terminal = false;
  };

  boatswainAutostart = pkgs.makeAutostartItem {
    name = "com.feaneron.Boatswain";
    package = pkgs.boatswain;
  };

  # ── Shared libraries for foreign (non-Nix) binaries ──
  #
  # NixOS has no /usr/lib, so a prebuilt ELF that was linked on Ubuntu finds
  # none of its DT_NEEDED libraries. `programs.nix-ld` below answers that: it
  # installs a shim at the FHS loader path every such binary names in its
  # PT_INTERP, and that shim searches this list. Anything NOT in this list is
  # invisible to every downloaded toolchain, pip wheel, npm postinstall,
  # AppImage and vendor SDK on the machine.
  #
  # The nix-ld module ships a default list, but assigning `libraries` REPLACES
  # it rather than extending it, so the module's own entries are restated here
  # (first group) instead of being silently dropped. The rest is the set a
  # "normal" distro would have had installed anyway, grouped by what tends to
  # need it. Adding to this list costs closure size and nothing else -- it
  # puts libraries on a search path, it does not put them on PATH or make them
  # available to the compiler at build time.
  #
  # A missing entry does not look like a missing library. It surfaces as
  # `error while loading shared libraries` from a program that worked
  # yesterday on another machine, or -- worse, for Python -- as a wheel that
  # installs perfectly and only fails at `import`.
  #
  # DO NOT DIAGNOSE THIS WITH `ldd`. It reports every soname on this list as
  # "not found" for a foreign binary that in fact runs perfectly, because ldd
  # invokes the loader directly and so never goes through the PT_INTERP shim
  # that does the resolving. An audit built on ldd output will report a
  # working toolchain as broken -- ~/.clang-tool-chain's ld.lld reads as
  # missing both libxml2.so.2 and libz.so.1 and still links. Run the binary
  # and read its exit status, or use `patchelf --print-needed` to see what it
  # wants and check those names against the shim directory:
  #
  #   ls /run/current-system/sw/share/nix-ld/lib
  #
  # The one real artefact of the libxml2 shim below is a warning, not a
  # failure: "no version information available", printed twice per ld.lld
  # invocation because the aliased 2.15 library carries different symbol
  # version tags than a real 2.9. It is noise in a build log and nothing
  # more; the link succeeds.
  legacySonameShims = pkgs.runCommand "legacy-soname-shims" { } ''
    mkdir -p $out/lib
    # libxml2 bumped its soname from .so.2 to .so.16 in 2.15, and nixpkgs is
    # past that bump. Prebuilt LLVM binaries are still linked against .so.2 --
    # the clang-tool-chain ld.lld that FastLED builds with refuses to start
    # without it. lld calls into libxml2 only to merge Windows COFF manifests
    # and never touches it on an ELF link, so aliasing the current library
    # under the old name is safe for that use. If something ever needs the
    # real 2.9-era ABI, pin an older libxml2 rather than widening this shim.
    ln -s ${pkgs.libxml2.out}/lib/libxml2.so $out/lib/libxml2.so.2
  '';

  foreignBinaryLibraries = with pkgs; [
    # The nix-ld module's own defaults, restated (see above).
    zlib zstd stdenv.cc.cc curl openssl attr libssh bzip2 libxml2 acl
    libsodium util-linux xz systemd

    # C/C++ runtime and the bits a compiler-adjacent tool links against.
    stdenv.cc.cc.lib libffi libxcrypt elfutils libunwind

    # libxcrypt-legacy as WELL as libxcrypt, because they ship different
    # sonames rather than different versions of one: current libxcrypt is
    # libcrypt.so.2, and everything built against glibc's old crypt still
    # asks for libcrypt.so.1. uv's prebuilt CPython 3.10 and 3.11 do, so
    # `import crypt` on those interpreters died with "libcrypt.so.1: cannot
    # open shared object file" -- the exact install-fine/import-fails shape
    # described above, and invisible until something reaches for it.
    # Harmless on 3.13, which dropped the crypt module entirely.
    libxcrypt-legacy

    # Console and scripting libraries. Prebuilt Python/Node builds and any
    # vendored interpreter want these.
    ncurses readline sqlite expat pcre2 icu

    # Compression beyond the defaults; used by toolchains that bundle their
    # own archivers.
    lz4 brotli snappy

    # Graphics/desktop. Electron apps, Playwright/Puppeteer browsers and
    # anything Qt- or GTK-based shipped as a tarball need the whole cluster,
    # and each missing one fails the same opaque way.
    glib gtk3 cairo pango atk gdk-pixbuf at-spi2-atk at-spi2-core
    nss nspr dbus fontconfig freetype
    libGL libdrm libxkbcommon mesa vulkan-loader
    xorg.libX11 xorg.libXcomposite xorg.libXdamage xorg.libXext
    xorg.libXfixes xorg.libXrandr xorg.libXrender xorg.libXi xorg.libXtst
    xorg.libXScrnSaver xorg.libxcb xorg.libXcursor xorg.libxshmfence

    # Audio and printing, for the same class of bundled desktop app.
    alsa-lib libpulseaudio cups

    # Sonames nixpkgs no longer ships under the name foreign binaries ask for.
    legacySonameShims
  ];

in
{
  # home-manager's NixOS module is added by flake.nix, alongside this file.
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
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

  # go/ links, Google-style: `go/hermes` in a browser's address bar lands on
  # the hermes kanban board and STAYS at go/hermes. Two halves. The hostname
  # `go` resolves to loopback via /etc/hosts (browsers treat a bare word with
  # a slash after it as a URL, not a search, so no scheme is needed), and
  # nginx on 127.0.0.1:80 answers for that name.
  #
  # It proxies rather than redirects, because a redirect would swap the
  # address bar to 127.0.0.1:9120/kanban and the point is the short name.
  # The catch is that hermes is a single-page app whose assets and API calls
  # are root-absolute (/assets/..., /api/..., websockets), so the catch-all
  # `/` on this host also has to proxy to the hermes origin or the page loads
  # as bare HTML. That means one host can carry one proxied app; a second
  # app would need its own hostname (`go2`, or `<name>.go`) rather than a
  # second entry here. Bound to loopback only, so nothing on the LAN can see
  # it and the firewall needs no hole.
  networking.extraHosts = "127.0.0.1 go";
  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    virtualHosts."go" = {
      listen = [ { addr = "127.0.0.1"; port = 80; } ];
      locations =
        let
          # hermes answers "invalid Host header" to anything but its own
          # address, so the proxied Host must be the upstream's, not `go`.
          # It has to sit in each location: proxyWebsockets emits
          # location-level proxy_set_header lines, and nginx then drops every
          # inherited one, so a server-level Host would silently vanish.
          hermes = path: {
            proxyPass = "http://127.0.0.1:9120${path}";
            proxyWebsockets = true;
            extraConfig = "proxy_set_header Host 127.0.0.1:9120;";
          };
        in {
          "= /hermes" = hermes "/kanban";
          "/" = hermes "";
        };
    };
  };

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

  # ── Default web browser ──
  # With Brave and Firefox both installed, nothing used to claim the web
  # mimetypes, so the "default" browser was whatever desktop-file cache order
  # served that day and flipped between rebuilds (the same instability the
  # dock and Stream Deck comments note where they invoke Brave by name).
  # This is the distro-level default; ~/.config/mimeapps.list (captured in
  # home/kde/) carries the same entries at the user level.
  xdg.mime.defaultApplications = {
    "text/html" = "brave-browser.desktop";
    "application/xhtml+xml" = "brave-browser.desktop";
    "x-scheme-handler/http" = "brave-browser.desktop";
    "x-scheme-handler/https" = "brave-browser.desktop";
    "x-scheme-handler/about" = "brave-browser.desktop";
    "x-scheme-handler/unknown" = "brave-browser.desktop";
  };

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  # ── Printing ──
  # Brother HL-L2395DW, mono laser, on the wired LAN. No Brother driver is
  # installed and none is wanted: the printer advertises image/urf and
  # image/pwg-raster, so CUPS drives it through IPP Everywhere and builds the
  # PPD itself from the device's own capabilities. That is strictly better
  # than brlaser or Brother's proprietary blob here -- it is what the printer
  # tells CUPS it can do, including the duplexer, and there is nothing to
  # break when nixpkgs moves.
  services.printing.enable = true;

  # The queue is addressed by mDNS name, not by 192.168.1.23. The name is
  # derived from the MAC (BRN + 3C2AF4D11C9A) and so never changes, whereas
  # the DHCP lease can -- and a queue pointing at a stale IP fails as "the
  # printer is broken", a long way from its actual cause.
  #
  # ensure-printers is its own oneshot unit rather than part of the
  # activation script, so if the printer is off at switch time the unit fails
  # and the rebuild still succeeds. `systemctl start ensure-printers` once it
  # is back.
  hardware.printers.ensureDefaultPrinter = "Brother_HL-L2395DW";
  hardware.printers.ensurePrinters = [
    {
      name = "Brother_HL-L2395DW";
      description = "Brother HL-L2395DW series";
      deviceUri = "ipp://BRN3C2AF4D11C9A.local/ipp/print";
      model = "everywhere";
      # Deliberately no ppdOptions. A cupsPrintQuality default was tried here
      # and removed: a driverless queue carries two parallel namespaces for
      # the same knob -- the PPD's cupsPrintQuality and the IPP
      # print-quality-default -- and setting the PPD one leaves `lpoptions`
      # and real jobs still reporting Normal, because clients read the IPP
      # attribute the device advertises. Setting both is possible but its
      # effect on output could not be confirmed, so the queue is left exactly
      # as `everywhere` and the printer negotiate it.
    }
  ];

  # cups-browsed auto-creates a queue for every printer it discovers over
  # DNS-SD. Switching avahi on therefore produced a second, implicitclass://
  # queue for this same printer, so both showed up in every print dialog with
  # nothing to tell them apart. The declared queue above is the one that
  # should exist; browsed has nothing left to contribute on a network with a
  # single, explicitly configured printer.
  services.printing.browsed.enable = false;

  # Avahi is what makes that .local name resolve, and separately what lets
  # CUPS find network printers at all -- without it `lpinfo -v` lists backend
  # schemes and no devices, which reads as "no printer on the network".
  # nssmdns4 wires .local into NSS so every program resolves it, not just
  # CUPS. openFirewall opens UDP 5353; mDNS is link-local by design and does
  # not cross the router.
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

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
    # NOT python3Packages.pip: it is a separate derivation from python3, so
    # `python3 -m pip` reports "No module named pip" while the `pip` binary it
    # does install can only ever fail PEP 668. Real pip lives in ~/.venv.
    #
    # NOT uv either, however tempting. scripts/03-apply-home.sh installs it
    # into the user's nix profile on purpose, because the system channel's uv
    # lags and clud/soldr track PyPI. An entry here would put uv on PATH,
    # satisfy that script's guard, skip the profile install, and leave a
    # restored machine on the older channel uv -- which is precisely what the
    # guard exists to prevent. The venv unit below does not need it here
    # either: its `path = [ pkgs.uv ]` pulls the derivation in by store path,
    # which is also what lets the venv provision at the very first login,
    # before 03-apply-home.sh has ever run.

    # pipx 1.8.0's own test suite fails against packaging >= 24, which
    # normalises the requirement spelling `black@ url` to `black @ url` while
    # tests/test_package_specifier.py still asserts the old form. Seven
    # cosmetic assertions then fail the build, and because pipx is in
    # systemPackages that failure takes system-path -- and so the entire
    # rebuild -- down with it. Nothing about installing or running apps is
    # affected, so the file is skipped rather than the package dropped.
    # Remove this override once nixpkgs ships pipx >= 1.9.
    (pipx.overridePythonAttrs (old: {
      disabledTestPaths = (old.disabledTestPaths or [ ]) ++ [
        "tests/test_package_specifier.py"
      ];
    }))
    brave
    telegram-desktop
    signal-desktop
    gh
    kitty
    imagemagick

    # Sublime Text. Needs the permittedInsecurePackages entry further down --
    # see the note there before removing either half.
    sublime4

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

    # ── Native toolchains ──
    #
    # Both compilers, on purpose: gcc is what a Linux build system assumes,
    # clang is what several projects here are actually built with (the FastLED
    # note by the nix-ld list above is one).
    #
    # gcc wins `cc`, `c++` and `cpp`. The two wrappers both ship those names,
    # and `system-path` is built with ignoreCollisions, so a collision is NOT
    # an error -- it silently keeps whichever package came first in this list,
    # which would make the identity of `cc` an accident of line order. The
    # lowPrio makes gcc the deterministic winner; `clang` and `clang++` are
    # unique names and are unaffected.
    #
    # These compile self-contained code and nothing else. There is no
    # /usr/include on NixOS, so anything that wants zlib, openssl or any other
    # library's headers still needs a `shell.nix` / `nix develop` (direnv is
    # enabled below) -- the nix-ld library list above puts shared objects on a
    # *runtime* search path and deliberately does not reach the compiler.
    # pkg-config is here for the same reason and with the same caveat: it
    # finds nothing until a dev shell populates PKG_CONFIG_PATH.
    gcc
    (lib.lowPrio clang)
    clang-tools         # clangd, clang-format, clang-tidy; not in `clang`
    binutils            # ld, as, ar, nm, objdump, readelf, strings
    gnumake
    cmake
    ninja
    pkg-config
    autoconf
    automake
    libtool
    gdb
    lldb

    # Profiling and the LLVM binutils. These were all "in the store but not
    # on PATH" -- present as build inputs of something else, so a `nix
    # why-depends` finds them and `command -v` does not, which is a
    # confusing pair of answers to get about the same tool.
    #
    # valgrind carries callgrind_annotate, cg_annotate and ms_print with it;
    # they are the readers for what valgrind's tools emit and are useless
    # separately, so the one entry covers all four names.
    valgrind

    # gcc_multi carries the 32-bit runtime and headers alongside the 64-bit
    # ones, which plain gcc on this channel does not: without it `-m32` fails at
    # link with "incompatible with elf64-x86-64" because there is no i686 glibc
    # or crt in the store at all.
    #
    # Wanted for profiling FastLED's fixed-point MP3 decoder. That decoder ships
    # to 32-bit targets, and x86-64 has been an actively misleading proxy for
    # them -- a change that cut the ESP32-C6 by 9.7% measured as a 3.2%
    # *regression* on the 64-bit host, because its whole benefit was avoiding
    # register spills that x86-64 has the registers to avoid anyway. A 32-bit
    # host build should reproduce that pressure and make the cheap, deterministic
    # host profile predictive again.
    gcc_multi
    # llvm-nm, llvm-size, llvm-objdump, llvm-symbolizer, llvm-profdata,
    # llvm-cov and the rest. Not redundant with binutils above: these read
    # LLVM bitcode and LLVM's own profile format, which GNU nm and size
    # cannot. Pinned to llvmPackages rather than a bare `llvm` so the version
    # tracks the clang above -- both are 21.1.8 today, and a profdata format
    # mismatch between clang and llvm-profdata is a silent wrong answer
    # rather than an error.
    llvmPackages.llvm
    # ld.lld, the LLVM linker, which was missing outright. Companion to mold
    # below rather than a replacement: mold is faster, lld is what a project
    # that hard-codes -fuse-ld=lld expects to find.
    lld
    # patchelf reads and rewrites DT_NEEDED and RPATH. On a machine where
    # foreign binaries find their libraries through nix-ld, it is the tool
    # that answers "what does this actually want?", and its absence sends
    # you to `ldd`, which lies here -- see the nix-ld note above.
    patchelf

    # mold, the fast linker. Nothing links with it until something asks:
    # `-fuse-ld=mold` on either compiler. Verified -- the resulting binary's
    # .comment section reads "mold 2.41.0 (compatible with GNU ld)" rather
    # than GNU ld's. gcc and clang find `ld.mold` on PATH, which is why this
    # entry is enough and no -B flag is needed; run either compiler with a
    # PATH that lacks /run/current-system/sw/bin and the flag fails with
    # "cannot find 'ld'" (gcc) or "invalid linker name" (clang), neither of
    # which reads like a PATH problem.
    #
    # `mold --run <build command>`, the other documented way in, does NOT work
    # here. pkgs.mold is a bintools *wrapper*, and the wrapper parses argv as
    # linker flags, so it rejects --run as an unknown option -- even though
    # the mold it wraps supports it and lists it in --help. (It is `--run` in
    # mold 2.x; the single-dash `-run` in older docs is gone.) Use
    # -fuse-ld=mold, or reach for the unwrapped binary knowing it bypasses the
    # wrapper's store-path handling.
    #
    # Deliberately NOT wired in as the system default linker. That would mean
    # overriding the cc-wrapper for the whole system, changing how every
    # derivation links and buying nothing -- nixpkgs builds arrive from the
    # binary cache already linked. The win is on code built by hand, which is
    # exactly where passing a flag is easy.
    mold

    # ── System administration ──
    inxi                # one-shot hardware/system report
    perf                # CPU hardware-counter profiling
    socat               # socket plumbing
    whois
    inetutils           # telnet, ftp, hostname, ping variants
    kdePackages.ksshaskpass  # graphical password prompt for sudo -A / ssh
    kdePackages.kdeplasma-addons  # supplies the quicklaunch panel widget
    voxtype             # push-to-talk voice-to-text (Meta+H)
    pciutils            # lspci; voxtype's GPU probe needs it to name the card

    # ── Stream Deck ──
    # An Elgato Stream Deck XL, 0fd9:006c, 32 keys.
    #
    # boatswain rather than streamdeck-ui, on three counts. It drives OBS
    # natively over obs-websocket, where streamdeck-ui has no OBS action at
    # all and would need a Command button shelling out to obs-cmd. It is
    # GTK4, so it is a native Wayland client and sidesteps the fractional
    # scaling that made the Qt app unusable on the previous Hyprland install
    # -- this machine runs 1.5x, 1.75x and 1x across three outputs, which is
    # exactly the case that breaks Qt. And the one advantage streamdeck-ui
    # had, a NixOS module that wires up udev, is worth nothing here.
    #
    # Nothing sets up device access, deliberately: systemd already does.
    # 70-av-production.hwdb maps usb:v0FD9p006C* to
    # ID_AV_PRODUCTION_CONTROLLER=1, and 70-uaccess.rules tags that property
    # on both the usb and hidraw subsystems, so the ACLs exist with no rule
    # of ours. Verified with getfacl on /dev/bus/usb/001/009 and
    # /dev/hidraw7: both already carried user:niteris:rw-. boatswain shipping
    # no udev rules of its own is therefore a non-issue rather than the cost
    # it first looked like. Upstream says the same from the other side --
    # Stream Decks work "starting from udev v250"; this is systemd 260.
    #
    # No uinput access either, and that is a choice. Key emulation would need
    # this user in the `uinput` group -- currently empty, and voxtype only
    # reaches uinput through ydotoold's socket -- which would let every
    # process this user runs inject keystrokes into any window. Launching
    # applications and driving OBS need none of it.
    boatswain
    boatswainAutostart
    chatgptLauncher     # "ChatGPT" entry for the Stream Deck to launch
    chatgptIcon         # its glyph; no icon theme ships one

    # ── Containers ──
    podman-desktop      # GUI for the Docker engine; see virtualisation.docker
    lazydocker          # TUI dashboard; what the "Docker" dock icon launches
    dockerIcon          # the whale glyph, no icon theme ships one
    dockerTui           # the "Docker" desktop entry itself
    docker-compose      # the standalone name; `docker compose` needs nothing

    alsa-utils          # amixer/aplay/arecord
    alsa-scarlett-gui   # 48V, gain, air, pad, direct monitor for the 2i2

    # ── Video editing ──
    # kdenlive rather than DaVinci Resolve: the free Linux Resolve ships no
    # H.264/AAC/H.265 at all -- Blackmagic will not pay the patent licence for
    # a build it gives away -- so it only ingests and emits DNxHR/ProRes and
    # every ordinary mp4 needs transcoding on the way in AND out. kdenlive
    # renders through MLT, which calls ffmpeg, so mp4 is just another format.
    #
    # Most of what people install alongside it is already inside the nixpkgs
    # derivation: frei0r (wrapped as FREI0R_PATH), glaxnimate, OpenTimelineIO
    # and ffmpeg-full are build inputs, and the app is patched to call this
    # exact melt and glaxnimate rather than searching $PATH. The entries below
    # are the parts that genuinely are NOT covered by that.
    kdePackages.kdenlive
    glaxnimate           # kdenlive embeds it, but this is the standalone app
    ffmpeg-full          # ffmpeg/ffprobe on the CLI; nvenc/nvdec are built in
    mediainfo            # says what is actually in a file when a clip misbehaves
    ladspaPlugins        # swh-plugins; see LADSPA_PATH below
    handbrake            # batch transcoder; `ghb` is the GUI, HandBrakeCLI the
                         # binary the package calls its mainProgram
  ];

  # nano is already installed and enabled by default on NixOS; make it the
  # editor every tool reaches for. neovim is available as `nvim` when wanted.
  environment.variables = {
    EDITOR = "nano";
    VISUAL = "nano";

    # Python's ssl module compiles in an OpenSSL default cert path that does not
    # exist on NixOS, so a venv interpreter has an empty verify path and every
    # HTTPS fetch fails with CERTIFICATE_VERIFY_FAILED. NixOS exports
    # NIX_SSL_CERT_FILE, which nixpkgs' own wrappers read; a plain venv python
    # does not know that name. SSL_CERT_FILE is the one OpenSSL itself honours,
    # and REQUESTS_CA_BUNDLE covers requests/urllib3, which ignore both.
    #
    # Without these, FastLED's clang-tool-chain cannot fetch its manifest and
    # re-downloads the whole toolchain on every clean build. This was the last
    # thing keeping a hand-rolled compatibility shim on PATH.
    SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
    REQUESTS_CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt";

    # MLT finds its LADSPA audio filters (pitch, reverb, declip, gate, the
    # rest of swh-plugins) through this. The nixpkgs mlt sets it, but only on
    # the `melt` wrapper -- so without this the effects appear when kdenlive
    # renders and are missing from its effect list while you edit. Setting it
    # here fixes the asymmetry, and hands the same plugins to any other LADSPA
    # host on the machine.
    LADSPA_PATH = "${pkgs.ladspaPlugins}/lib/ladspa";
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

  # Starship's stock `directory` shows the path relative to the enclosing git
  # repo, truncated to three components -- so `~/dev/nixos/system` renders as
  # `nixos/system` and `~/src/nixos/system` renders identically. The prompt is
  # the one place the working directory is always on screen, so spell it out
  # in full, `~`-relative, and let it be the thing you can trust.
  programs.starship.settings.directory = {
    truncate_to_repo = false;
    truncation_length = 0;   # 0 = do not truncate
  };
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
        # gpu-cuda maps to whisper-rs/cuda, which builds ggml's CUDA backend.
        # Viable only since the card moved to the proprietary driver: nouveau
        # exposes no CUDA at all.
        cargoBuildFeatures =
          (old.cargoBuildFeatures or [ ]) ++ [ "osd-gtk4" "gpu-cuda" ];
        # Checks stay off the GPU feature: cargo test would need a working
        # CUDA device inside the build sandbox, which it does not have.
        cargoCheckFeatures = (old.cargoCheckFeatures or [ ]) ++ [ "osd-gtk4" ];

        # nvcc is a NATIVE input - it runs on the builder - and CUDA_PATH is
        # what lets whisper.cpp's cmake find_package(CUDAToolkit) succeed,
        # since whisper-rs drives cmake from its own build.rs and never sees
        # this derivation's cmakeFlags.
        nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
          prev.cudaPackages.cuda_nvcc
          prev.addDriverRunpath
        ];
        CUDA_PATH = "${prev.cudaPackages.cudatoolkit}";

        # The version-check hook runs `voxtype --version` in the sandbox,
        # where there is no NVIDIA driver and so no real libcuda.so.1 -- the
        # binary cannot even start. Nothing is wrong with it; a CUDA build is
        # simply not runnable where no GPU driver exists, so the check has to
        # go rather than be satisfied.
        doInstallCheck = false;

        # -lcuda is the DRIVER library, and it is deliberately not in the
        # toolkit: it ships with the installed driver and must match it. The
        # toolkit provides a stub to link against, so point the linker at
        # that. postFixup below is the other half -- without it the stub
        # would also be the thing loaded at runtime, and every CUDA call
        # would fail against a library that implements nothing.
        NIX_LDFLAGS = "-L${prev.cudaPackages.cuda_cudart}/lib/stubs";
        # sm_86 is the GA106. Naming it avoids compiling the fat binary for
        # every architecture ggml supports, which dominates the build.
        CMAKE_CUDA_ARCHITECTURES = "86";

        buildInputs = (old.buildInputs or [ ]) ++ (with prev; [
          gtk4
          gtk4-layer-shell
          cairo
          glib
          cudaPackages.cuda_cudart
          cudaPackages.libcublas
        ]);

        # Strip the stub directory back out of RPATH and add the driver's
        # own path instead. cc-wrapper turns every store -L into an RPATH
        # entry, so without this the stub libcuda.so.1 sits ahead of the
        # real one at /run/opengl-driver/lib and wins the lookup.
        postFixup = (old.postFixup or "") + ''
          for f in "$out"/bin/.voxtype-wrapped "$out"/bin/voxtype-osd \
                   "$out"/bin/voxtype-osd-gtk4; do
            [ -e "$f" ] || continue
            rp=$(patchelf --print-rpath "$f" \
                   | tr ':' '\n' | grep -v '/lib/stubs$' | paste -sd:)
            patchelf --set-rpath "$rp" "$f"
            addDriverRunpath "$f"
          done
        '';
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

    # Grow BAR1 past its 256 MiB default. BAR1 is the aperture through which
    # the CPU reaches VRAM; every Wayland surface needing a CPU-visible
    # mapping consumes VA space in it. At 256 MiB a burst -- Chromium
    # spawning a renderer asks for ~25 mappings at once -- fragments the
    # free list and the allocator fails *with 200 MiB nominally free*:
    #
    #   NVRM: dmaAllocMapping_GM107: can't alloc VA space for mapping.
    #   NVRM: NV_ERR_NO_MEMORY ... reusemappingdbMap(&pBar1VaInfo->reuseDb, ...)
    #   [drm:__nv_drm_gem_nvkms_map] *ERROR* Failed to map NvKmsKapiMemory
    #
    # nvidia-drm then returns -ENOMEM, Chromium's media code CHECKs, and the
    # CHECK compiles to ud2 -- which is why a Brave tab dies with SIGILL and
    # not a segfault. NVIDIA has reproduced this (bug 5762513); it is
    # Wayland-only and unfixed across 580 through 610, so there is no driver
    # version to upgrade to. See issue #1.
    #
    # This param makes the driver call pci_resize_resource() itself, so it
    # does NOT need Re-Size BAR support in firmware -- only somewhere to put
    # a bigger window. That is why it was pointless until Above 4G Decoding
    # was enabled in BIOS: every BAR sat below 4 GiB in a 288 MiB hole with
    # zero slack. With Above 4G on, the GPU's BARs moved to 0x7fe0000000 and
    # there is room to grow.
    #
    # Bonus: the fragmentation is self-inflicted at exactly 256 MiB.
    # kern_bus.c:505 only relaxes 64 KB mapping granularity when
    # `bar1SizeMB > 256`, and 256 is not > 256 -- so every tiny cursor and UI
    # surface burns a full 64 KB slot. Any size above 256 MiB clears that too.
    moduleParams.nvidia.NVreg_EnableResizableBar = 1;
  };

  # Hand read access to keyd's virtual keyboard alone, in place of
  # membership of the `input` group -- which grants every process the user
  # runs read access to every /dev/input/event*, the real keyboard
  # included.
  #
  # This is the whole reason the hotkey lives on a device keyd owns: keyd
  # grabs only the Compx mouse, so the sole events on this node are the two
  # mouse buttons it re-emits. Reading it reveals no typing whatsoever.
  #
  # A dedicated group rather than TAG+="uaccess". uaccess works through
  # logind, which only puts ACLs on devices attached to a seat, and keyd's
  # node is virtual (/devices/virtual/input/...) with no seat -- the tag
  # applies and no ACL ever appears. Verified: TAGS did contain uaccess
  # while getfacl showed nothing.
  users.groups.voxtype-input = { };
  services.udev.extraRules = ''
    SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="keyd virtual keyboard", GROUP="voxtype-input", MODE="0640"
  '';

  # ── Key remapping ───────────────────────────────────────────
  # Push-to-talk is a spare mouse button. Its firmware emits KEY_LEFTSHIFT
  # (code 42) on the mouse's keyboard interface, which is unusable as a
  # hotkey directly -- shift is a modifier needed for ordinary typing. keyd
  # rewrites it to F14, but ONLY on 25a7:fa0a, the Compx mouse. Nobody
  # types capitals on a mouse, so nothing is lost there, and the real
  # keyboards never see this mapping: the Compx *keyboard* is a separate
  # product id (25a7:fa09) and the SONiX is 0c45:8008.
  #
  # keyd rather than binding code 42 in voxtype directly, because voxtype's
  # listener only READS keys and never consumes them. Left as shift, every
  # dictation would also send shift to the focused window; as F14 it sends
  # something no application acts on. The same reasoning retired the
  # earlier Super+H mapping -- holding a letter key leaked ~200 h's into
  # whatever had focus.
  #
  # Deliberately NOT matching "*": a wildcard would also grab ydotoold's
  # virtual device, which is what voxtype types transcriptions through, so
  # keyd would be remapping voxtype's own output.
  services.keyd = {
    enable = true;
    keyboards.compx-mouse = {
      ids = [ "25a7:fa0a" ];
      settings.main = {
        # Spare button by the thumb; firmware sends KEY_LEFTSHIFT.
        leftshift = "f14";
        # Thumb side button (BTN_SIDE, code 275). It is NOT a spare: it is
        # the button browsers navigate Back with, which binding it outright
        # silently took away. So it is shared by duration instead -- a
        # normal click still goes Back, holding it past 200ms pastes.
        #
        # S-insert rather than C-v for the paste half: Ctrl+V collides with
        # what terminal programs already use it for (vim's visual block,
        # readline's quoted insert), whereas Shift+Insert is paste in GTK,
        # Qt and browsers and is claimed by essentially no TUI.
        #
        # A consequence of timeout() worth knowing: the Back click is
        # emitted on RELEASE rather than press, since keyd cannot know
        # which half you meant until then.
        mouse1 = "timeout(mouse1, 200, S-insert)";
      };
    };
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

  # Turn the music down while the hotkey is held, and put it back on release.
  # Two reasons: you can hear yourself, and the mic is an open Wave:3 sitting
  # in front of the speakers, so whatever is playing is also going into
  # whisper.
  #
  # Driven off voxtype's state file rather than its pre_recording_command /
  # post_output_command hooks. The hooks fire either side of *typing*, so any
  # path that ends a recording without producing output -- VAD hearing no
  # speech, an empty transcription, a cancel -- ducks without ever undoing it,
  # and the music stays down until you dictate again. The state file always
  # comes back to "idle", so a watcher on it cannot get stuck; it is also what
  # `voxtype record toggle` and `voxtype status` already read.
  systemd.user.services.voxtype-duck =
    let
      duck = pkgs.writeShellApplication {
        name = "voxtype-duck";
        runtimeInputs = with pkgs; [
          pipewire        # pw-dump
          wireplumber     # wpctl
          jq
          inotify-tools
          gawk
          coreutils
        ];
        text = ''
          RUNDIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/voxtype"
          STATE="$RUNDIR/state"
          # Deliberately beside RUNDIR, not inside it: writing the save file
          # into the directory this service watches makes it wake itself up
          # on its own bookkeeping.
          SAVE="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/voxtype-ducked"
          LEVEL="''${VOXTYPE_DUCK_LEVEL:-0.3}"

          # Every playback stream except voxtype's own and OBS's. voxtype
          # holds an ALSA playback stream open for its start/stop beeps, and
          # ducking that would quiet the very cue that says recording began.
          # OBS only ever plays back to monitor -- into the OBS Mix sink and
          # out to whoever is watching -- so ducking it would duck the
          # broadcast rather than the room. \b keeps that from also matching
          # an unrelated name that merely starts with "obs".
          streams() {
            pw-dump | jq -r '
              .[]
              | select(.info.props."media.class" == "Stream/Output/Audio")
              | select(((.info.props."node.name" // "")
                        + (.info.props."application.name" // ""))
                       | ascii_downcase
                       | test("voxtype|\\bobs\\b") | not)
              | .id'
          }

          # Per-stream, not the sink: touching the sink volume would make
          # Plasma pop its volume OSD on every dictation, and would fight any
          # volume change made while recording. Saved volumes go to a file so
          # a restart of this service still knows what to put back.
          duck() {
            if [ -e "$SAVE" ]; then return 0; fi
            local ids tmp id vol
            ids="$(streams)" || return 0
            tmp="$(mktemp "$SAVE.XXXXXX")"
            for id in $ids; do
              vol="$(wpctl get-volume "$id" | awk '{print $2}')" || continue
              [ -n "$vol" ] || continue
              printf '%s %s\n' "$id" "$vol" >> "$tmp"
              # wpctl's scale is cubic, not linear: 0.5 there is 0.125 of the
              # actual amplitude (verified against pw-dump's channelVolumes).
              # So LEVEL scales roughly perceived loudness, and small values
              # get very quiet very fast.
              wpctl set-volume "$id" \
                "$(awk -v v="$vol" -v f="$LEVEL" 'BEGIN{printf "%.2f", v*f}')" || true
            done
            mv "$tmp" "$SAVE"
          }

          restore() {
            if [ ! -e "$SAVE" ]; then return 0; fi
            local id vol
            while read -r id vol; do
              # A stream that ended while ducked is simply gone; ignore it.
              wpctl set-volume "$id" "$vol" 2>/dev/null || true
            done < "$SAVE"
            rm -f "$SAVE"
          }

          # Anything that is not "recording" -- idle, transcribing, a state
          # this version has never heard of -- means the music comes back, so
          # the music returns the moment the button is released rather than
          # waiting out the transcription.
          apply() {
            case "$(cat "$STATE" 2>/dev/null)" in
              recording) duck ;;
              *)         restore ;;
            esac
          }

          case "''${1:-watch}" in
            duck)    duck ;;
            restore) restore ;;
            apply)   apply ;;
            watch)
              # The daemon creates this directory, but this service may win the
              # race to start; inotifywait exits immediately on a missing path.
              mkdir -p "$RUNDIR"
              apply   # in case a recording is already in flight
              inotifywait -q -m -e modify,close_write,create,moved_to "$RUNDIR" \
                | while read -r _; do apply; done
              ;;
          esac
        '';
      };
    in
    {
      description = "Duck playback audio while voxtype is recording";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" "voxtype.service" ];

      # Fraction of each stream's current volume to duck to, on wpctl's cubic
      # scale. 0.3 is well down but still audible; 0.0 would be a mute.
      environment.VOXTYPE_DUCK_LEVEL = "0.3";

      serviceConfig = {
        ExecStart = "${duck}/bin/voxtype-duck watch";
        # Never leave the volume down because the watcher died mid-recording.
        ExecStopPost = "${duck}/bin/voxtype-duck restore";
        Restart = "always";
        RestartSec = 2;
      };
    };

  # ── Screen capture and streaming ─────────────────────────────
  # OBS. Screen capture on this machine goes through xdg-desktop-portal-kde
  # (already present with Plasma), not X11 capture, so the "Screen Capture
  # (PipeWire)" source is the one that works on Wayland -- the older
  # "Screen Capture (XSHM)" source sees nothing.
  programs.obs-studio.enable = true;

  # Per-application audio capture. Without it OBS can only take a whole
  # PipeWire device, so a stream picks up every notification and browser tab
  # along with the Wave:3 and the Scarlett. This adds "Application Audio
  # Capture (PipeWire)" sources that bind to one program at a time.
  programs.obs-studio.plugins = [ pkgs.obs-studio-plugins.obs-pipewire-audio-capture ];

  # The virtual camera carries video and nothing else. v4l2loopback has no
  # audio side at all, and OBS's virtual camera on Windows and macOS has none
  # either -- it is a video device by definition, which is why mixing audio
  # into it could not be made to work there. What does work is a virtual
  # *microphone* standing next to the virtual camera: the far end picks
  # "OBS Cam" for video and "OBS Mic" for audio, and gets the full OBS mix.
  #
  # One loopback module builds both halves. Its capture side is a sink,
  # "OBS Mix", which is what OBS is pointed at as its monitoring device; its
  # playback side is a source, "OBS Mic", which every application sees as an
  # ordinary microphone. Whatever OBS monitors comes out of it.
  #
  # Keys are quoted because PipeWire wants literal dotted names: written bare,
  # Nix would read `node.name` as nesting and emit {"node":{"name":...}},
  # which the config parser does not understand.
  services.pipewire.extraConfig.pipewire."99-obs-virtual-mic" = {
    "context.modules" = [{
      name = "libpipewire-module-loopback";
      args = {
        "node.description" = "OBS Mic";
        "capture.props" = {
          "node.name" = "obs_mix";
          "node.description" = "OBS Mix";
          "media.class" = "Audio/Sink";
          "audio.position" = [ "FL" "FR" ];
        };
        "playback.props" = {
          "node.name" = "obs_mic";
          "node.description" = "OBS Mic";
          "media.class" = "Audio/Source";
          "audio.position" = [ "FL" "FR" ];
          # Never let this outrank a real microphone as the default input.
          # voxtype records from whatever the default source is, so a virtual
          # mic winning that election would have dictation transcribing OBS's
          # own output instead of the Wave:3.
          "priority.session" = 100;
        };
      };
    }];
  };

  # The virtual camera, wired up by hand rather than with
  # programs.obs-studio.enableVirtualCamera. That option hard-codes
  # `video_nr=1` into boot.extraModprobeConfig, and the Cam Link 4K already
  # owns /dev/video0 and /dev/video1 -- so v4l2loopback would be fighting it
  # for a device number, with the winner decided by whether the module loads
  # before USB enumeration finishes. Changing just that number would take
  # mkForce on boot.extraModprobeConfig, which is a shared `lines` option
  # that also carries the nvidia lines, NVreg_EnableResizableBar among them.
  #
  # So: the same three settings the option would have made, with video_nr=9,
  # clear of anything a capture device will claim.
  #
  # A new out-of-tree module does not load on the switch that adds it:
  # modprobe resolves against /run/booted-system, which is still the old
  # closure, so systemd-modules-load logs "Failed to find module
  # 'v4l2loopback'" and carries on. A reboot fixes it; without one,
  #   sudo modprobe -d /run/current-system/kernel-modules v4l2loopback
  # loads it out of the new closure. That was done here, so /dev/video9
  # exists now and will come back on its own at every boot.
  boot.extraModulePackages = [ config.boot.kernelPackages.v4l2loopback ];
  boot.kernelModules = [ "v4l2loopback" ];
  boot.extraModprobeConfig = ''
    options v4l2loopback devices=1 video_nr=9 card_label="OBS Cam" exclusive_caps=1
  '';

  # ── Containers ─────────────────────────────────────────────
  # Docker Desktop itself cannot be installed here, and this is the stand-in.
  # Desktop ships only as a .deb/.rpm that unpacks into /opt with its own
  # systemd user units and runs the engine inside a QEMU VM -- none of which
  # survives a NixOS closure, and there is no `docker-desktop` attribute in
  # nixpkgs to fall back on. On Linux that VM is pure overhead anyway: the
  # kernel already has the cgroups and namespaces containers are made of, so
  # the native engine is both the only option and the faster one.
  #
  # What Desktop bundles is the daemon, the CLI, compose, buildx and a
  # dashboard. The first four are this single option: nixpkgs bakes the
  # compose and buildx cli-plugin store paths into the `docker` binary itself,
  # so `docker compose` and `docker buildx` work with nothing else declared
  # (both paths are greppable inside pkgs.docker's bin/docker). The dashboard
  # is podman-desktop, in systemPackages above -- despite the name it drives a
  # plain Docker socket, so it is the containers/images/volumes UI without the
  # VM.
  virtualisation.docker = {
    enable = true;

    # Off at boot, up on first use. Socket activation is now unconditional in
    # the NixOS module (the old virtualisation.docker.socketActivation option
    # was removed for that reason), so /var/run/docker.sock exists from boot
    # and any `docker` command starts dockerd transparently. That matches how
    # Desktop behaves and keeps an idle daemon off a workstation that can go
    # days without touching a container.
    #
    # The one thing it gives up: a container created with `--restart=always`
    # does not come back after a reboot until something pokes the socket. Set
    # this to true if a long-lived container -- a local registry, a database
    # -- ever needs to survive on its own.
    enableOnBoot = false;
  };

  # GPU passthrough for containers, via CDI rather than the old runtime shim.
  # This generates a Container Device Interface spec describing the 3060 and
  # every driver library a container needs, drops it in /var/run/cdi, and
  # flips `features.cdi` on in the daemon (automatic for docker >= 25; we are
  # on 29). A udev rule regenerates the spec whenever the nvidia device
  # changes, so a driver upgrade does not leave a stale one behind.
  #
  # NOT `virtualisation.docker.enableNvidia`. That option is deprecated, and
  # what it actually does is register a wrapper runtime so `--runtime=nvidia`
  # works -- the pre-CDI mechanism. CDI is the replacement and needs no
  # runtime wrapper at all.
  #
  # The invocation this gives you, and the ONLY one that works here:
  #
  #   docker run --rm --device=nvidia.com/gpu=all <image> nvidia-smi
  #
  # and in compose, a plain `devices:` entry -- NOT a deploy.resources block:
  #
  #   services:
  #     train:
  #       devices: [ "nvidia.com/gpu=all" ]
  #
  # `--gpus all` does NOT work, and cannot be made to. Moby 29 dropped the
  # legacy nvidia device-driver shim outright -- the string
  # "nvidia-container-runtime-hook" does not appear anywhere in its dockerd
  # binary -- so there is nothing left for `--gpus` to dispatch nvidia to. It
  # now resolves purely through CDI, and on this machine it fails with the
  # thoroughly unhelpful `Error response from daemon: AMD CDI spec not found`,
  # which is about the last vendor it tried and nothing to do with the actual
  # problem. Compose's older
  # `deploy.resources.reservations.devices[].driver = "nvidia"` form goes
  # through the same removed path and fails with `could not select device
  # driver "nvidia" with capabilities: [[gpu]]`. Both are worth recognising,
  # because every tutorial online still uses them.
  #
  # `docker info` is the way to confirm the wiring: it lists the discovered
  # devices as `cdi: nvidia.com/gpu=0` and `cdi: nvidia.com/gpu=all`.
  #
  # One caveat inherent to the approach: the host's driver libraries are
  # bind-mounted into the container from their store paths, so the CUDA
  # userspace in an image has to be compatible with THIS host's driver
  # version. It is the host driver that matters, never the image's.
  hardware.nvidia-container-toolkit.enable = true;

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

  # The same problem one level up: a script or test fixture that hard-codes
  # `/bin/true`, `/bin/sleep`, `/bin/echo` or `#!/usr/bin/python3` fails on
  # stock NixOS, where /bin holds only `sh` and /usr/bin only `env`. envfs
  # mounts a FUSE filesystem over both directories that resolves any name
  # present on PATH, so those paths work without a hand-maintained list of
  # symlinks that goes stale.
  #
  # Found via soldr's test suite, where four tests fail on this machine and
  # nowhere else: two spawn `/bin/true`, one spawns `/bin/echo`, and a cargo-doc
  # fixture needs `/bin/sleep`, `dirname` and `mkdir` from a stripped PATH.
  # They pass on every CI runner, so the failures read as real defects until
  # someone notices the host is the variable.
  #
  # Only names that exist on PATH resolve; envfs invents nothing. It replaces
  # NixOS's own /bin/sh and /usr/bin/env with its own equivalents, which is why
  # this is one switch rather than an `environment.etc` pile.
  services.envfs.enable = true;

  # This is a development workstation where profiling ordinary processes is
  # expected. -1 removes perf_event's access restrictions, so unprivileged
  # local processes may use CPU counters rather than needing CAP_PERFMON.
  # It also permits kernel, raw, and system-wide events: those can expose
  # system-wide activity, so keep this setting specific to this trusted box.
  boot.kernel.sysctl."kernel.perf_event_paranoid" = -1;

  # ...and this is what that loader is allowed to find. Declared in the
  # let-block above, where the reasoning and the per-group notes live.
  programs.nix-ld.libraries = foreignBinaryLibraries;

  # Put uv tool shims (~/.local/bin) and the user venv (~/.venv/bin) on PATH
  # for every session, not just interactive bash via ~/.bashrc. NixOS puts
  # these ahead of the default entries, which is the point: ~/.venv/bin has to
  # beat /run/current-system/sw/bin so that `python3`, `python` and `pip` all
  # mean the writable venv rather than the immutable store interpreter.
  #
  # Shadowing the system python is safe here specifically because every Nix
  # application has an absolute /nix/store shebang and never consults PATH.
  # The blast radius is interactive shells and scripts run by hand -- which is
  # exactly the set of things that were previously forced through `uv`.
  environment.sessionVariables.PATH = [ "$HOME/.venv/bin" "$HOME/.local/bin" ];

  # pipx builds each app its own venv, and needs a base interpreter to build
  # them from. Point it at the same uv-managed CPython the user venv uses, not
  # at pkgs.python3: an app venv on the store python names a /nix/store path
  # in its shebang, and dies at the next nix-collect-garbage.
  environment.sessionVariables.PIPX_DEFAULT_PYTHON = "${userPythonHome}/bin/python3";

  # Build ~/.venv on first login, and rebuild it if it is ever deleted.
  #
  # Why a venv at all: nixpkgs' python3 ships PEP 668's EXTERNALLY-MANAGED, so
  # `pip install` refuses rather than trying to write to the immutable
  # /nix/store. That refusal is correct and must not be papered over with
  # --break-system-packages, which would scatter packages into
  # ~/.local/lib/pythonX.Y/site-packages -- a directory that is on sys.path
  # for EVERY interpreter on the box, so one bad wheel breaks unrelated tools,
  # and which is silently orphaned the day nixpkgs moves 3.13 to 3.14.
  #
  # Why a uv-managed CPython rather than pkgs.python3: a venv records its
  # interpreter's absolute path in pyvenv.cfg. Built on the store python, that
  # path is a /nix/store entry which the next `nix-collect-garbage` removes,
  # and the venv dies with "no such file or directory" for an interpreter that
  # worked yesterday. The uv interpreter lives under ~/.local/share and is
  # invisible to the garbage collector.
  #
  # Binary wheels (numpy, pillow, torch) then work because programs.nix-ld
  # above supplies libstdc++ and friends. Without nix-ld the pip install still
  # SUCCEEDS and only the later import fails, which is a confusing way to find
  # out -- so the two settings belong together.
  systemd.user.services.user-python-venv = {
    description = "Provision the user's writable Python venv at ~/.venv";
    wantedBy = [ "default.target" ];
    path = [ pkgs.uv ];
    environment.SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    # Both steps are idempotent, so every login after the first costs a stat.
    # There is no network-online.target for user units; if the first login
    # races the network this fails and the next login provisions it.
    script = ''
      set -eu
      uv python install ${userPythonVersion}
      if [ ! -x "$HOME/.venv/bin/pip" ]; then
        uv venv --seed --python ${userPythonVersion} "$HOME/.venv"
      fi
    '';
  };

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
    # Deliberately NOT in "input". That group grants read access to every
    # /dev/input/event* (they are root:input 0660), which means every
    # process running as this user could read every keystroke on the real
    # keyboard - a keylogger surface covering passwords and everything
    # else. voxtype needed it only to see its hotkey.
    #
    # The udev rule below replaces it with access to exactly one device:
    # keyd's virtual keyboard. keyd grabs only the Compx mouse, so that
    # device carries the mouse buttons and nothing else - the SONiX never
    # passes through it. voxtype gets the key it needs and no typing at all.
    #
    # "docker" is knowingly root-equivalent, and is the exception to the
    # paragraph above: the daemon runs as root and will bind-mount any path
    # into a container, so anyone who can reach its socket can read and write
    # the whole filesystem as root without ever going through sudo. There is
    # no narrower group -- membership *is* the API -- and rootless docker
    # trades it for a userspace network stack and no GPU passthrough, which
    # this machine's CUDA work wants. Accepted for a single-user workstation
    # where that user is already in "wheel".
    # "dialout" owns the USB CDC/UART character devices that MCU boards enumerate
    # as -- /dev/ttyACM* for the ESP32-C6's built-in USB JTAG/serial, /dev/ttyUSB*
    # for CP210x and FTDI bridges. They are crw-rw---- root:dialout, so without
    # this every flash and every serial-monitor attach fails with EACCES, which
    # esptool reports as "the port is busy or doesn't exist" -- a message that
    # sends you looking for a stuck process rather than at group membership.
    # FastLED's `bash autoresearch <board>` needs it to deploy to hardware.
    extraGroups = [ "networkmanager" "wheel" "ydotool" "voxtype-input" "docker" "dialout" ];
    packages = with pkgs; [
      kdePackages.kate
    #  thunderbird
    ];
  };

  # Install firefox.
  programs.firefox.enable = true;

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Sublime Text is a vendored binary that nixpkgs patchelfs, and its rpath
  # names openssl_1_1 unconditionally (pkgs/applications/editors/sublime/4,
  # `neededLibraries`) -- the dev build 4205 included, so there is no newer
  # Sublime to move to. 1.1.1 went EOL in September 2023, so nixpkgs marks it
  # insecure and refuses to evaluate the package at all without this list.
  # Without it the failure names openssl, not sublime, which reads like an
  # unrelated dependency problem.
  #
  # Read this as a global permit, not a per-package one: it unblocks
  # openssl-1.1.1w for ANYTHING in this configuration that asks for it, which
  # is why it is worth re-checking rather than leaving forever. Today the only
  # taker is Sublime, and only for TLS it does on its own behalf -- license
  # checks and Package Control. Nothing on this machine routes traffic through
  # it. `nix why-depends` against a future system generation is how to confirm
  # that is still true:
  #
  #   nix why-depends /run/current-system \
  #     $(nix eval --raw .#nixosConfigurations.nixos.pkgs.openssl_1_1)
  nixpkgs.config.permittedInsecurePackages = [ "openssl-1.1.1w" ];
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
  # ── Declarative Plasma (home-manager + plasma-manager) ──
  # NixOS manages SYSTEM state, but Plasma panels are USER state, which plain
  # configuration.nix cannot reach. home-manager supplies that layer and
  # plasma-manager declares the panel on top of it. Both are flake inputs now,
  # locked in flake.lock; `nix flake update` is what moves them.
  home-manager.users.niteris =
    { ... }:
    {
      imports = [ inputs.plasma-manager.homeModules.plasma-manager ];
      home.stateVersion = "26.05";

      programs.plasma = {
        enable = true;

        # ── Key repeat ──
        # KWin's own defaults are 600ms then 25 repeats a second, slow enough
        # that holding an arrow key across a line of code is barely quicker
        # than tapping it. 250ms/50Hz halves the wait and doubles the rate.
        # plasma-manager caps repeatRate at 100.0 and repeatDelay at 5000, so
        # there is headroom if 50 still feels slow.
        #
        # What was actually asked for was an ACCELERATING repeat -- gentle at
        # first, very fast past ~3 seconds -- and that is worth recording as
        # unavailable rather than as untried. Nothing in this stack ramps:
        # KDE Wayland has exactly one delay and one rate (these two keys),
        # and keyd only repeats `macro()` bindings, at its own fixed
        # macro_repeat_timeout -- for an ordinary key it just forwards the
        # hold and KWin generates every repeat. A ramp therefore needs a
        # daemon that EVIOCGRABs the real keyboards and re-emits its own tap
        # pairs through uinput, putting custom code in the path of the only
        # keyboard on a machine with no staging. That was offered and turned
        # down in favour of the flat rate; it remains the only way to get a
        # ramp if the flat rate disappoints.
        #
        # KeyRepeat is pinned even though "repeat" is already KWin's default,
        # because it is the one key in this group that can turn repeat off
        # outright ("nothing"), and kcminputrc is now written wholesale from
        # here -- so the mode is worth stating rather than inheriting.
        #
        # DO NOT VERIFY THIS WITH `wl_keyboard.repeat_info`. That is the
        # obvious check and it reads as a failure when the change worked:
        #
        #   WAYLAND_DEBUG=1 timeout 8 kwrite /tmp/x 2>&1 | grep -m1 repeat_info
        #
        # reports rate 0 both before and after (only the delay moves, 600 ->
        # 250). The zero is deliberate and permanent: KWin 6.6 repeats keys
        # SERVER-side for any client new enough to bind wl_keyboard with
        # `key_state_repeated`, and zeroes the advertised rate so the client
        # does not also repeat on its own. Its own timer still runs at the
        # rate below -- the number is simply not visible in that event.
        #
        # XWayland binds an older wl_keyboard and so still receives the real
        # rate, which makes the X server the honest read-out:
        #
        #   xset q | grep -A1 "auto repeat delay"   -> delay 250, rate 50
        #
        # Applying without a re-login takes a trick. plasma-manager writes
        # this ini in python rather than through `kwriteconfig6 --notify`, so
        # no KConfig change signal is emitted, KWin's KConfigWatcher never
        # fires, and nixos-rebuild switch leaves the running session on the
        # old values. `kwriteconfig6 --notify` does fire it -- but only when
        # it actually CHANGES a value, and by then the file already holds
        # what you want, so re-writing the same number is a silent no-op.
        # Nudge through a different value and back:
        #
        #   kwriteconfig6 --notify --file kcminputrc \
        #       --group Keyboard --key RepeatDelay 251     # then again with 250
        #
        # One such change re-runs KWin's whole reconfigure(), which re-reads
        # all three keys, so nudging any one of them is enough.
        input.keyboard = {
          repeatDelay = 250;   # ms before the first repeat
          repeatRate = 50.0;   # repeats per second thereafter
        };
        configFile.kcminputrc.Keyboard.KeyRepeat = "repeat";

        # ── Idle behaviour ──
        # Stock Plasma dims at 5 minutes, blanks at 10 and locks at 5, which
        # is far too eager for a desktop that sits in one room. Nothing now
        # touches the screen for half an hour, and the session stays unlocked
        # for four.
        #
        # Note what that combination means: from 30 minutes the screen is
        # dark but the session is still open, and any keypress before the
        # four-hour mark lands straight on the desktop with no password. That
        # is the ask, and it is the right trade for a machine at home; it
        # would not be on a laptop that leaves the house.
        kscreenlocker = {
          autoLock = true;
          timeout = 240;    # minutes -- 4 hours, and KDE's own ceiling
        };

        powerdevil.AC = {
          # seconds here, minutes above: powerdevil and kscreenlocker
          # genuinely disagree about units, so 1800 and 240 are 30 minutes
          # and 4 hours respectively, not a typo in either direction.
          turnOffDisplay.idleTimeout = 1800;

          # Dimming is off rather than merely postponed. Left enabled it
          # keeps its own 5-minute default and the screen still fades on you
          # at 5 minutes, which is the behaviour being complained about --
          # moving only the blank timeout would look like the change had not
          # worked.
          dimDisplay.enable = false;

          # No idle suspend, ever. PowerDevil's default AC action is to sleep,
          # and on 2026-09-01 it fired while the machine sat unattended:
          # powerdevil's wakeupsourcehelper started, logind announced "The
          # system will suspend now!", the box entered S3 -- and woke again
          # inside the same second. (Wake source undetermined; the "root hub
          # lost power or was reset" lines are logged on every resume and
          # prove nothing.) That round trip resets the GPU, and every OpenGL
          # client loses its context and its VRAM at once:
          #
          #   kwin_wayland: A graphics reset attributable to the current GL
          #                 context occurred.
          #   plasmashell:  KCrash ... handleContextCreationFailure
          #
          # Chromium apps notice GL_GUILTY_CONTEXT_RESET and restart their GPU
          # process; plasmashell crashes and respawns. kitty does neither -- it
          # keeps drawing against the dead context, so frames and backgrounds
          # still paint while the glyph atlas comes back empty. The symptom is
          # terminals full of nothing, which reads as "kitty broke" when the
          # shells underneath are untouched. Recover them without closing them
          # by reloading kitty's config, which rebuilds the atlas in place:
          #
          #   pkill -USR1 -x .kitty-wrapped
          #
          # That name is not a typo and `pkill -x kitty` matches NOTHING --
          # same wrapper trap as boatswain above; kitty's comm is
          # `.kitty-wrapped`.
          #
          # logind is not a second trigger: its IdleAction is `ignore`
          # (busctl get-property org.freedesktop.login1 /org/freedesktop/login1
          # org.freedesktop.login1.Manager IdleAction), so PowerDevil was the
          # only thing that could have started this, and this one setting is
          # the whole fix. A desktop with no battery gains nothing from
          # suspending anyway; explicit sleep from the menu still works, only
          # the idle trigger goes away.
          #
          # Two gotchas when changing this. plasma-manager asserts idleTimeout
          # must stay unset for action "nothing", so do not add one. And its
          # powerdevil module registers no restartServices, so a switch writes
          # ~/.config/powerdevilrc and leaves the running daemon on the old
          # value until next login -- kick it by hand:
          #
          #   qdbus org.kde.Solid.PowerManagement \
          #     /org/kde/Solid/PowerManagement refreshStatus
          autoSuspend.action = "nothing";
        };

        panels = [
          # ── Which monitor the panels live on ──
          # `screen = 0` on BOTH, and it is load-bearing. Leaving it unset
          # does NOT mean "the primary screen", which is what the comment
          # here used to claim: plasma-manager then emits no lastScreen at
          # all and the panels land wherever plasmashell felt like putting
          # them. On the run that added Sublime to the dock, both panels
          # jumped from the primary 4K to DP-1, the small top-left monitor,
          # having sat on the right one for months -- nothing about screens
          # had changed, only the launcher list. So an unset screen is not a
          # stable default, it is an unspecified one, and every panel rebuild
          # re-rolls it.
          #
          # The index is Plasma's own screen numbering, not the connector
          # name, and 0 is the primary. Read the mapping back with:
          #
          #   qdbus org.kde.plasmashell /PlasmaShell \
          #     org.kde.PlasmaShell.evaluateScript '
          #       for (var i = 0; i < screenCount; i++) {
          #         var g = screenGeometry(i);
          #         print(i + ": " + g.x + "," + g.y);
          #       }
          #       var p = panels();
          #       for (var j = 0; j < p.length; j++) print(j + " -> " + p[j].screen);'
          #
          # Today 0 is HDMI-A-1 at 2560,443. Rearranging the monitors in
          # System Settings can renumber that, and plasma-manager accepts
          # only integers here, so there is no connector name to pin instead.
          #
          # Setting screen at all also makes plasma-manager add
          # plasma-plasmashell to its own restartServices, which is the same
          # restart the icon-cache trap below needs anyway.

          # A compact, fit-to-content panel keeps the clock at the top centre
          # without turning it into a second full-width bar.
          {
            location = "top";
            screen = 0;
            alignment = "center";
            lengthMode = "fit";
            widgets = [ "org.kde.plasma.digitalclock" ];
          }
          {
            location = "bottom";
            screen = 0;
            widgets = [
              "org.kde.plasma.kickoff"
              "org.kde.plasma.pager"
              # Launchers, and only launchers. An Icons-only Task Manager
              # merges a running window INTO the launcher that started it --
              # that is the whole point of the icons-only design -- so a
              # minimized window has no entry of its own and appears to
              # vanish back into its own launcher icon. Splitting the two
              # jobs across two widgets is the only way to tell them apart.
              # quicklaunch never shows windows at all.
              {
                name = "org.kde.plasma.quicklaunch";
                config.General.launcherUrls = lib.concatStringsSep "," dockLaunchers;
              }

              # An expanding spacer either side is what centres the window
              # list. fill = false below is the other half: a task manager
              # left to fill would eat the whole gap and sit hard against the
              # launchers, which is where it was before. Sized to its content
              # and floated between two spacers, it lands mid-panel instead.
              {
                panelSpacer = {
                  expanding = true;
                };
              }

              # Windows, and only windows: `launchers = [ ]` is load-bearing,
              # not a placeholder. This is where a minimized window goes --
              # mid-panel, distinct from the launcher it came from.
              #
              # To make this show ONLY minimized windows rather than every
              # window, add: behavior.showTasks.onlyMinimized = true;
              {
                iconTasks = {
                  launchers = [ ];
                  appearance.fill = false;
                };
              }

              {
                panelSpacer = {
                  expanding = true;
                };
              }

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
