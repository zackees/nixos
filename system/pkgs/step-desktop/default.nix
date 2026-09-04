# Two Plasma containment-action plugins, local.stepdesktop.previous and
# local.stepdesktop.next, so that a mouse button on the desktop background
# can step one virtual desktop. Nothing shipped with Plasma does this: bound
# to a button press, org.kde.switchdesktop opens a menu of desktops. Built
# against the same kdePackages the desktop runs, so it follows the overlay.
{ stdenv, cmake, kdePackages }:
stdenv.mkDerivation {
  pname = "plasma-containmentactions-stepdesktop";
  version = "1";
  src = ./.;
  nativeBuildInputs = [ cmake kdePackages.extra-cmake-modules ];
  # libplasma's exported target links KF6::ConfigCore, KF6::KirigamiPlatform
  # and Qt6::Qml, and its cmake config only finds those if they are on the
  # prefix path here, so the transitive set is spelled out.
  buildInputs = with kdePackages; [ qtbase qtdeclarative libplasma kcoreaddons kconfig kirigami ki18n kpackage ksvg kguiaddons kwindowsystem ];
  # A plugin, not an app: nothing to wrap, and the Qt hook insists otherwise.
  dontWrapQtApps = true;
  # ECM would otherwise ask Qt where its plugins live and try to install
  # into qtbase's own store path.
  cmakeFlags = [ "-DKDE_INSTALL_USE_QT_SYS_PATHS=OFF" "-DKDE_INSTALL_QTPLUGINDIR=lib/qt-6/plugins" ];
}
