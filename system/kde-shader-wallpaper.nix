{ pkgs, src }:
pkgs.stdenv.mkDerivation {
  pname = "kde-shader-wallpaper";
  version = "4.0.0-unstable-2026-10-06";
  inherit src;
  nativeBuildInputs = [ pkgs.cmake pkgs.pkg-config pkgs.kdePackages.extra-cmake-modules ];
  buildInputs = with pkgs.kdePackages; [
    qtbase qtdeclarative qtmultimedia libplasma kconfig ki18n kpackage
  ] ++ [ pkgs.pipewire pkgs.libxcb pkgs.wayland pkgs.wayland-protocols pkgs.shaderc ];
  # This is a plugin loaded into Plasma's existing Qt process, not an app.
  dontWrapQtApps = true;
}
