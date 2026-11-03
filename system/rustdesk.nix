# RustDesk: remote support, for taking control of someone else's computer
# from this one. The client only, on RustDesk's public ID/relay servers --
# they do the NAT hole punching, so neither side opens a port. A self-hosted
# hbbs/hbbr is a separate decision (it needs a public IP and port forwards).
#
# The upstream AppImage rather than nixpkgs: the pinned channel has 1.4.7 and
# unstable 1.5.0, and the release asked for was 1.5.1. The hash is the
# sha256 digest GitHub publishes for the asset. To bump, take the new
# version's digest from
#   gh api repos/rustdesk/rustdesk/releases/tags/<v> --jq '.assets[].digest'
{ pkgs, ... }:

let
  pname = "rustdesk";
  version = "1.5.1";
  src = pkgs.fetchurl {
    url = "https://github.com/rustdesk/rustdesk/releases/download/${version}/rustdesk-${version}-x86_64.AppImage";
    sha256 = "bb8b7ccb3f50a201dccdc89b46385cff90f33e60b4730faeda9fa5504ac4dce6";
  };
  contents = pkgs.appimageTools.extractType2 { inherit pname version src; };
  rustdesk = pkgs.appimageTools.wrapType2 {
    inherit pname version src;
    extraInstallCommands = ''
      for d in ${contents}/*.desktop ${contents}/usr/share/applications/*.desktop; do
        [ -e "$d" ] || continue
        install -Dm444 "$d" "$out/share/applications/rustdesk.desktop"
        break
      done
      # Upstream's Exec is relative (usr/share/rustdesk/rustdesk), which only
      # resolves inside the AppImage; launched from a menu it fails silently.
      sed -i -E "s|^Exec=[^ ]*|Exec=$out/bin/rustdesk|; s|^Name=rustdesk$|Name=RustDesk|" \
        "$out/share/applications/rustdesk.desktop"
      icon=$(find ${contents} -name 'rustdesk.png' -path '*256x256*' | head -1)
      [ -n "$icon" ] || icon=$(find ${contents} -maxdepth 1 -name '*.png' | head -1)
      install -Dm444 "$icon" "$out/share/icons/hicolor/256x256/apps/rustdesk.png"
    '';
  };
in
{
  environment.systemPackages = [ rustdesk ];
}
