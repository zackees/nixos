# The graphical sudo prompt: password plus a One time / 15 minutes / 4 hours
# choice for how long the ticket lasts. Replaces ksshaskpass for sudo -A;
# see main.cpp for how the duration is enforced, and the sudo block in
# configuration.nix for the sudoers side of it.
{ stdenv, cmake, qt6 }:
stdenv.mkDerivation {
  pname = "sudo-askpass";
  version = "1";
  src = ./.;
  nativeBuildInputs = [ cmake qt6.wrapQtAppsHook ];
  buildInputs = [ qt6.qtbase qt6.qtwayland ];
}
