{ pkgs }:
# Build a Plasma widget (plasmoid) from a source directory, failing the
# build if any of its QML would not load.
#
# QML is only parsed when plasmashell instantiates it -- for a popup, the
# first time someone opens it -- so a broken widget otherwise ships cleanly
# and fails in front of the user ("Type SidePopup unavailable": a
# Connections placed as a PlasmaCore.Dialog child, whose default property
# only takes an Item). qmllint, given the real Qt, Kirigami and Plasma type
# information from the same nixpkgs the desktop runs, reports that class of
# error statically. Every warning fails the build except `unqualified`,
# which is style (bare `foo` vs `root.foo`), not a load failure.
#
#   mkPlasmoid { name = "tasks"; src = ./tasks/applet;
#                substitutions = { "@TASKS@" = "${tasks}/bin/tasks"; }; }
{ name, src, substitutions ? { } }:
let
  qmlPath = pkgs.lib.concatMapStringsSep " " (p: "-I ${p}/lib/qt-6/qml") (
    [ pkgs.qt6.qtdeclarative ]
    ++ (with pkgs.kdePackages; [ libplasma kirigami.unwrapped plasma5support plasma-workspace ])
  );
  substitute = pkgs.lib.concatStringsSep " " (
    pkgs.lib.mapAttrsToList (k: v: "--replace-fail ${pkgs.lib.escapeShellArg k} ${pkgs.lib.escapeShellArg v}") substitutions
  );
in
pkgs.runCommand "${name}-applet" { nativeBuildInputs = [ pkgs.qt6.qtdeclarative ]; } ''
  mkdir -p $out
  cp -r ${src}/. $out/
  chmod -R u+w $out
  ${pkgs.lib.optionalString (substitutions != { }) "substituteInPlace $out/contents/ui/main.qml ${substitute}"}

  status=0
  for f in $(find $out -name '*.qml'); do
    out_lint=$(qmllint ${qmlPath} --unqualified disable "$f" 2>&1) || status=1
    if printf '%s\n' "$out_lint" | grep -qE '^(Warning|Error)'; then
      printf '%s\n' "$out_lint" >&2
      status=1
    fi
  done
  if [ "$status" != 0 ]; then
    echo "${name}: QML lint failed; this widget would not load in plasmashell" >&2
    exit 1
  fi
''
