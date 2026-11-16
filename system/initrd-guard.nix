# Build-time check that the initrd we actually built can mount the root
# filesystem.
#
# The eval-time assertion in configuration.nix (search "stage1Paths") checks
# the *config*: that each stage-1 filesystem's type is named in the initrd
# module list. This checks the *artifact*: it unpacks the built initrd and
# confirms every module stage 1 is supposed to have is really in there,
# together with everything modules.dep says it needs. The two fail
# differently -- a module list can be right while the initrd is still wrong
# (boot.initrd.allowMissingModules silently drops what the kernel lacks, a
# module's dependency can be left out of the closure, a kernel bump can move
# a driver out of the builtins) -- and every one of those builds and
# switches cleanly and only shows up at the next boot, with no journal
# because the journal lives on the disk that will not mount. That is how
# 2026-10-30 to 11-16 was lost to a missing ext4.ko.
#
# It lives in system.checks, so it is a dependency of the toplevel and a
# failure fails `nixos-rebuild build`.
{ config, lib, pkgs, ... }:

let
  kernel = config.boot.kernelPackages.kernel;
  initrd = config.system.build.initialRamdisk;

  # Same stage-1 set as the assertion in configuration.nix: what stage 1
  # mounts before switching root.
  stage1Paths = [ "/" "/nix" "/nix/store" "/var" "/var/log" "/var/lib" "/etc" "/usr" ];
  stage1Fs = lib.filter
    (fs: fs.neededForBoot || lib.elem fs.mountPoint stage1Paths)
    (lib.attrValues config.fileSystems);

  # Filesystems Linux cannot build as modules at all, or that name no
  # driver. "auto" is probed at mount time, so there is nothing to check.
  pseudoFs = [ "tmpfs" "ramfs" "proc" "sysfs" "devtmpfs" "rootfs" "none" "auto" ];

  # Kconfig symbol per filesystem, to recognise one built into the kernel
  # (=y). Anything not listed falls back to <TYPE>_FS, which covers most.
  fsSymbol = {
    vfat = "VFAT_FS"; msdos = "MSDOS_FS"; exfat = "EXFAT_FS";
    nfs = "NFS_FS"; nfs4 = "NFS_V4"; cifs = "CIFS"; smb3 = "CIFS";
    squashfs = "SQUASHFS"; overlay = "OVERLAY_FS"; ntfs3 = "NTFS3_FS";
    "9p" = "9P_FS"; virtiofs = "VIRTIO_FS"; iso9660 = "ISO9660_FS";
  };
  symbolFor = t: fsSymbol.${t} or "${lib.toUpper t}_FS";

  # One requirement per line: kind, name, Kconfig symbol (fs only), reason.
  requirements = pkgs.writeText "initrd-requirements.tsv" (lib.concatStrings (
    map (fs: "fs\t${fs.fsType}\t${symbolFor fs.fsType}\t"
          + "driver for the ${fs.fsType} filesystem at ${fs.mountPoint}, which stage 1 mounts\n")
      (lib.filter (fs: !lib.elem fs.fsType pseudoFs) stage1Fs)
    ++ map (m: "mod\t${m}\t-\tlisted in boot.initrd.kernelModules (loaded unconditionally in stage 1)\n")
      config.boot.initrd.kernelModules
    ++ map (m: "mod\t${m}\t-\tlisted in boot.initrd.availableKernelModules\n")
      config.boot.initrd.availableKernelModules
  ));

  check = pkgs.writeShellScript "initrd-guard-check" ''
    # usage: initrd-guard-check INITRD REQUIREMENTS KERNEL_CONFIG KERNEL_MODDIR WORKDIR
    set -euo pipefail
    initrd=$1 reqs=$2 kconfig=$3 kmoddir=$4 work=$5
    modver=$(basename "$kmoddir")

    # -- Find the compressed main archive. NixOS prepends uncompressed cpio
    # segments (the CPU microcode) and pads them with NULs; walk past each
    # one's TRAILER!!! and the padding until a compression magic shows up.
    hex_at() { od -An -v -tx1 -j "$1" -N "$2" "$initrd" | tr -d ' \n'; }
    trailers=$(grep -obUaF 'TRAILER!!!' "$initrd" | cut -d: -f1 || true)
    size=$(stat -c %s "$initrd")
    off=0 decomp=
    while [ -z "$decomp" ]; do
      [ "$off" -lt "$size" ] || { echo "initrd-guard: no compressed archive found in $initrd" >&2; exit 1; }
      magic=$(hex_at "$off" 6)
      case $magic in
        28b52ffd*)    decomp="zstd -dc" ;;
        fd377a585a00) decomp="xz -dc" ;;
        1f8b*)        decomp="gzip -dc" ;;
        30373037303[12])
          t=$(printf '%s\n' $trailers | awk -v o="$off" '$1 > o { print; exit }')
          [ -n "$t" ] || { echo "initrd-guard: cpio at offset $off has no trailer" >&2; exit 1; }
          # First non-NUL byte after the trailer name is the next segment.
          start=$((t + 10))
          rel=$(od -An -v -tu1 -j "$start" -N 1048576 "$initrd" \
            | awk '{ for (i = 1; i <= NF; i++) { if (f == "" && $i != 0) f = n; n++ } } END { print f }')
          [ -n "$rel" ] || { echo "initrd-guard: only padding after the cpio at offset $off" >&2; exit 1; }
          off=$((start + rel)) ;;
        *) echo "initrd-guard: unrecognised data at offset $off of $initrd (magic $magic);" \
                "expected cpio, zstd, xz or gzip" >&2; exit 1 ;;
      esac
    done
    echo "initrd-guard: main archive at offset $off ($decomp)"

    mkdir -p "$work/root"
    tail -c +$((off + 1)) "$initrd" | $decomp | (cd "$work/root" && cpio -id --quiet --no-absolute-filenames)

    # /lib in the initrd is a symlink to an absolute store path, which in
    # this sandbox would point at nothing (or worse, the host). Search the
    # unpacked tree itself, never following links.
    moddir=
    for d in "$work"/root/nix/store/*/lib/modules/"$modver"; do
      [ -f "$d/modules.dep" ] && moddir=$d
    done
    [ -n "$moddir" ] || { echo "initrd-guard: no lib/modules/$modver/modules.dep inside the initrd" >&2; exit 1; }
    echo "initrd-guard: checking $moddir against kernel $modver"

    # norm VAR PATH: module name of PATH, with - folded to _, into VAR
    # (no subshell: this runs once per line of modules.builtin).
    norm() { local b=''${2##*/}; b=''${b%%.ko*}; printf -v "$1" '%s' "''${b//-/_}"; }

    declare -A builtin=() depline=() present=()
    while IFS= read -r p; do norm n "$p"; builtin[$n]=1; done < "$kmoddir/modules.builtin"
    while IFS= read -r line; do
      norm n "''${line%%:*}"; depline[$n]=$line
    done < "$moddir/modules.dep"
    while IFS= read -r f; do norm n "$f"; present[$n]=''${f#"$moddir"/}; done \
      < <(find "$moddir" \( -name '*.ko' -o -name '*.ko.xz' -o -name '*.ko.zst' -o -name '*.ko.gz' \) -not -type l)

    failures=0 checked=0
    fail() { echo "initrd-guard: MISSING $1" >&2; failures=$((failures + 1)); }

    check_module() {
      local mod=$1 why=$2 line dep
      norm n "$mod"
      checked=$((checked + 1))
      if [ -n "''${builtin[$n]:-}" ]; then
        echo "  ok  $mod (built into the kernel)"; return
      fi
      if [ -z "''${present[$n]:-}" ]; then
        fail "module '$mod': no $mod.ko[.xz|.zst|.gz] in the initrd. Needed because: $why."
        return
      fi
      line=''${depline[$n]:-}
      if [ -z "$line" ]; then
        fail "module '$mod': ''${present[$n]} is in the initrd but has no modules.dep entry, so modprobe cannot load it. Needed because: $why."
        return
      fi
      local ok=1
      for dep in ''${line#*:}; do
        if [ ! -f "$moddir/$dep" ]; then
          ok=
          fail "module '$dep', a dependency of '$mod' per modules.dep, is not in the initrd, so '$mod' cannot load. '$mod' is needed because: $why."
        fi
      done
      [ -n "$ok" ] && echo "  ok  $mod (''${present[$n]}, $(( $(wc -w <<<"''${line#*:}") )) deps)"
      return 0
    }

    while IFS=$'\t' read -r kind name sym why; do
      case $kind in
        fs)
          if grep -qx "CONFIG_$sym=y" "$kconfig"; then
            echo "  ok  $name filesystem (CONFIG_$sym=y, built in)"; continue
          fi
          # The kernel requests filesystem drivers as "fs-<type>"; resolve
          # that the same way (ext2/ext3 are served by ext4, for one).
          mod=$(awk -v a="fs-$name" '$1 == "alias" && $2 == a { print $3; exit }' "$kmoddir/modules.alias")
          check_module "''${mod:-$name}" "$why" ;;
        mod) check_module "$name" "$why" ;;
      esac
    done < "$reqs"

    if [ "$failures" -gt 0 ]; then
      echo "initrd-guard: $failures problem(s) in the built initrd ($initrd)." >&2
      echo "initrd-guard: this machine would fail to boot it. If boot.initrd.availableKernelModules" >&2
      echo "initrd-guard: is lib.mkForce'd in system/configuration.nix, name the module there." >&2
      exit 1
    fi
    echo "initrd-guard: all $checked required modules and their dependencies are present"
  '';
in
{
  system.checks = [
    (pkgs.runCommand "initrd-guard" {
      nativeBuildInputs = with pkgs; [ coreutils gnugrep gawk cpio zstd xz gzip findutils ];
      passthru = { inherit check requirements; };
    } ''
      ${check} ${initrd}/initrd ${requirements} ${kernel.configfile} \
        ${kernel.modules}/lib/modules/${kernel.modDirVersion} "$TMPDIR/initrd-guard" > report 2>&1 || status=$?
      chmod -R u+w "$TMPDIR/initrd-guard" 2>/dev/null || true
      cat report
      [ "''${status:-0}" -eq 0 ] || exit 1
      cp report "$out"
    '')
  ];
}
