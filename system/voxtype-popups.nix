{ pkgs, lib, ... }:
let
  python = pkgs.python3.withPackages (p: [ p.pygobject3 ]);
  popup = pkgs.stdenvNoCC.mkDerivation {
    name = "voxtype-popup";
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.wrapGAppsHook4 pkgs.gobject-introspection ];
    buildInputs = [ pkgs.gtk4 pkgs.gtk4-layer-shell ];
    installPhase = ''
      mkdir -p $out/bin
      cp ${./voxtype-popup.py} $out/bin/voxtype-popup
      substituteInPlace $out/bin/voxtype-popup --replace-fail '#!/usr/bin/env python3' '#!${python}/bin/python3'
      chmod +x $out/bin/voxtype-popup
    '';
    preFixup = ''
      gappsWrapperArgs+=(--prefix LD_PRELOAD : ${pkgs.gtk4-layer-shell}/lib/libgtk4-layer-shell.so)
    '';
  };
  # Voxtype's existing binary wrapper prepends libnotify to PATH. Replace only
  # that direct reference, retaining its CUDA setup and avoiding a Rust rebuild.
  # replaceDirectDependencies requires the replacement to keep the same name.
  notify = pkgs.runCommand pkgs.libnotify.name { } ''
    mkdir -p $out/bin
    for entry in ${pkgs.libnotify}/*; do
      [ "$(basename "$entry")" = bin ] || ln -s "$entry" $out/
    done
    cat > $out/bin/notify-send <<'NOTIFY'
    #!${pkgs.runtimeShell}
    exec ${python}/bin/python3 ${./voxtype-popup.py} --send "$@"
    NOTIFY
    chmod +x $out/bin/notify-send
  '';
  voxtype = pkgs.replaceDirectDependencies {
    drv = pkgs.voxtype;
    replacements = [{ oldDependency = pkgs.libnotify; newDependency = notify; }];
  };
in {
  systemd.user.services.voxtype-popup = {
    description = "Voxtype notifications on the lower right of the main screen";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${popup}/bin/voxtype-popup";
      Restart = "on-failure";
      RestartSec = 2;
    };
  };
  systemd.user.services.voxtype = {
    requires = [ "voxtype-popup.service" ];
    after = [ "voxtype-popup.service" ];
    serviceConfig.ExecStart = lib.mkForce "${voxtype}/bin/voxtype daemon";
  };
}
