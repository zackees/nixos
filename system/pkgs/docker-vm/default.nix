{ lib, stdenv, requireFile, autoPatchelfHook, wrapGAppsHook3, makeWrapper
, makeDesktopItem, copyDesktopItems, gtk3, webkitgtk_4_1, glib, libsoup_3
, gst_all_1, docker, docker-compose, zenity }:

# Pinned local build; keep the release archive when backing up this machine.
# The source checkout and temporary Cargo target are not runtime dependencies.
stdenv.mkDerivation {
  pname = "docker-vm";
  version = "2026-09-13";
  src = requireFile {
    name = "docker-vm-2026-09-13.tar.gz";
    sha256 = "1s7kniklm71hhy18hmdaqk13ajfsvdqdhvh6y9crv6dpwhmmnr0d";
    message = ''
      Restore ~/.local/share/docker-vm/releases/docker-vm-2026-09-13.tar.gz
      from backup, then run nix-store --add-fixed sha256 on that archive.
    '';
  };
  nativeBuildInputs = [ autoPatchelfHook wrapGAppsHook3 makeWrapper copyDesktopItems ];
  buildInputs = [ gtk3 webkitgtk_4_1 glib libsoup_3 stdenv.cc.cc.lib
    gst_all_1.gstreamer gst_all_1.gst-plugins-base gst_all_1.gst-plugins-good ];
  dontBuild = true;
  # These scripts run inside Debian, where /nix/store does not exist.
  dontPatchShebangs = true;
  desktopItems = [ (makeDesktopItem {
    name = "docker-vm";
    desktopName = "Private Desktop";
    comment = "Isolated, RAM-only Chromium desktop";
    exec = "docker-vm";
    icon = "docker-vm";
    terminal = false;
    categories = [ "Network" "RemoteAccess" ];
    startupWMClass = "docker-vm-viewer";
  }) ];
  installPhase = ''
    runHook preInstall
    mkdir -p $out/libexec $out/bin $out/share/pixmaps
    cp bin/docker-vm-viewer $out/libexec/
    cp -r share/docker-vm $out/share/
    cp share/icons/hicolor/256x256/apps/docker-vm.png $out/share/pixmaps/
    makeWrapper $out/libexec/docker-vm-viewer $out/bin/docker-vm \
      --run 'ulimit -c 0' \
      --set DOCKER_VM_RESOURCE_DIR $out/share/docker-vm \
      --set GDK_BACKEND x11 \
      --set LIBGL_ALWAYS_SOFTWARE 1 \
      --set WEBKIT_DISABLE_COMPOSITING_MODE 1 \
      --prefix PATH : ${lib.makeBinPath [ docker docker-compose zenity ]}
    runHook postInstall
  '';
  meta = {
    description = "Private Docker desktop canvas";
    platforms = [ "x86_64-linux" ];
    mainProgram = "docker-vm";
  };
}
