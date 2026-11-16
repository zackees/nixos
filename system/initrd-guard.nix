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

  # In 26.05 these options are attrsOf bool (accepting lists), so a name can
  # be vetoed with `name = false`; read them either way.
  enabledNames = v: if builtins.isAttrs v then lib.attrNames (lib.filterAttrs (_: on: on) v) else v;

  forbidden = pkgs.writeText "initrd-forbidden.txt"
    (lib.concatMapStrings (m: "${m}\n") config.local.initrdGuard.forbiddenModules);

  # One requirement per line: kind, name, Kconfig symbol (fs only), reason.
  requirements = pkgs.writeText "initrd-requirements.tsv" (lib.concatStrings (
    map (fs: "fs\t${fs.fsType}\t${symbolFor fs.fsType}\t"
          + "driver for the ${fs.fsType} filesystem at ${fs.mountPoint}, which stage 1 mounts\n")
      (lib.filter (fs: !lib.elem fs.fsType pseudoFs) stage1Fs)
    ++ map (m: "mod\t${m}\t-\tlisted in boot.initrd.kernelModules (loaded unconditionally in stage 1)\n")
      (enabledNames config.boot.initrd.kernelModules)
    ++ map (m: "mod\t${m}\t-\tlisted in boot.initrd.availableKernelModules\n")
      (enabledNames config.boot.initrd.availableKernelModules)
  ));

  check = pkgs.writeShellScript "initrd-guard-check" ''
    # usage: initrd-guard-check INITRD REQUIREMENTS KERNEL_CONFIG KERNEL_MODDIR WORKDIR FORBIDDEN
    set -euo pipefail
    initrd=$1 reqs=$2 kconfig=$3 kmoddir=$4 work=$5 forbidden=$6
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

    # -- Aliases. A listed name need not be a module file name: NixOS's
    # systemd initrd asks for "autofs", which is `alias autofs autofs4`, and
    # the kernel asks for filesystems as "fs-<type>". modprobe resolves
    # these through modules.alias, so do the same: the initrd's own copy
    # first (that is what stage 1's modprobe reads; depmod regenerates it
    # for just the shipped modules), then the kernel's full one (so a name
    # whose module was left out still resolves to the module to report),
    # then the builtin modules' aliases from modules.builtin.modinfo.
    # Wildcard modaliases (pci:v*...) cannot match a plain name; skip them.
    declare -A alias_initrd=() alias_kernel=() alias_builtin=()
    # Written to files rather than read through <(...), so a failing awk
    # stops the check under set -e instead of silently resolving nothing.
    plain='function plain(s) { return s !~ /[*?:]/ && index(s, "[") == 0 }'
    : > "$work/alias.initrd"; : > "$work/alias.kernel"; : > "$work/alias.builtin"
    for src in "$moddir/modules.alias:initrd" "$kmoddir/modules.alias:kernel"; do
      [ -f "''${src%:*}" ] || continue
      awk "$plain"' $1 == "alias" && plain($2) { a = $2; m = $3; gsub(/-/, "_", a); gsub(/-/, "_", m); print a, m }' \
        "''${src%:*}" > "$work/alias.''${src##*:}"
    done
    if [ -f "$kmoddir/modules.builtin.modinfo" ]; then
      tr '\0' '\n' < "$kmoddir/modules.builtin.modinfo" > "$work/builtin.modinfo"
      awk -F'[.]alias=' "$plain"' NF == 2 && plain($2) { a = $2; m = $1; gsub(/-/, "_", a); gsub(/-/, "_", m); print a, m }' \
        "$work/builtin.modinfo" > "$work/alias.builtin"
    fi
    while read -r a m; do [ -n "''${alias_initrd[$a]:-}" ] || alias_initrd[$a]=$m; done < "$work/alias.initrd"
    while read -r a m; do [ -n "''${alias_kernel[$a]:-}" ] || alias_kernel[$a]=$m; done < "$work/alias.kernel"
    while read -r a m; do [ -n "''${alias_builtin[$a]:-}" ] || alias_builtin[$a]=$m; done < "$work/alias.builtin"
    echo "initrd-guard: aliases: $(wc -l < "$work/alias.initrd") initrd, $(wc -l < "$work/alias.kernel") kernel, $(wc -l < "$work/alias.builtin") builtin"

    # resolve NAME: sets r (normalised module name) and via (the alias
    # source, empty when NAME is itself a module). A real module name wins
    # over an alias of the same spelling, as in modprobe.
    resolve() {
      norm r "$1"; via=
      if [ -n "''${present[$r]:-}''${depline[$r]:-}''${builtin[$r]:-}" ]; then return 0; fi
      if [ -n "''${alias_initrd[$r]:-}" ]; then r=''${alias_initrd[$r]}; via="initrd modules.alias"
      elif [ -n "''${alias_kernel[$r]:-}" ]; then r=''${alias_kernel[$r]}; via="kernel modules.alias"
      elif [ -n "''${alias_builtin[$r]:-}" ]; then r=''${alias_builtin[$r]}; via="modules.builtin.modinfo"
      fi
    }

    failures=0
    failmsgs=()
    fail() { echo "initrd-guard: $1" >&2; failmsgs+=("$1"); failures=$((failures + 1)); }

    # -- Collect requirements first, keyed by normalised module name, so a
    # module wanted for several reasons is checked and reported once with
    # all of them (ext4 is both the root fs driver and a listed module).
    # Keyed by the RESOLVED name, so "autofs" and "autofs4" are one entry.
    declare -A reasons=() display=() aliasnote=()
    order=()
    want() {
      local mod=$1 why=$2
      resolve "$mod"
      if [ -n "$via" ]; then
        case ", ''${aliasnote[$r]:-}, " in
          *", '$mod' via $via, "*) ;;
          *) aliasnote[$r]+="''${aliasnote[$r]:+, }'$mod' via $via" ;;
        esac
      fi
      if [ -z "''${reasons[$r]:-}" ]; then
        order+=("$r"); display[$r]=$r; reasons[$r]=$why
        [ -n "$via" ] || display[$r]=$mod
      else
        case "; ''${reasons[$r]}; " in *"; $why; "*) ;; *) reasons[$r]+="; $why" ;; esac
      fi
    }
    while IFS=$'\t' read -r kind name sym why; do
      case $kind in
        fs)
          if grep -qx "CONFIG_$sym=y" "$kconfig"; then
            echo "  ok  $name filesystem (CONFIG_$sym=y, built in)"; continue
          fi
          # The kernel requests filesystem drivers as "fs-<type>"; resolve
          # that the same way. With no such alias, assume the module is
          # named after the type, so the report still names something.
          resolve "fs-$name"
          if [ -n "$via" ]; then want "fs-$name" "$why"; else want "$name" "$why"; fi ;;
        mod) want "$name" "$why" ;;
      esac
    done < "$reqs"

    # -- Everything required must be present, with its modules.dep closure.
    for n in "''${order[@]}"; do
      mod=''${display[$n]} why=''${reasons[$n]}
      note=''${aliasnote[$n]:+; resolved from alias ''${aliasnote[$n]}}
      if [ -n "''${builtin[$n]:-}" ]; then
        echo "  ok  $mod (built into the kernel$note)"; continue
      fi
      if [ -z "''${present[$n]:-}" ]; then
        fail "MISSING module '$mod': no $mod.ko[.xz|.zst|.gz] in the initrd''${note:+ (''${note#; })}. Needed because: $why."
        continue
      fi
      line=''${depline[$n]:-}
      if [ -z "$line" ]; then
        fail "MISSING module '$mod': ''${present[$n]} is in the initrd but has no modules.dep entry''${note:+ (''${note#; })}, so modprobe cannot load it. Needed because: $why."
        continue
      fi
      ok=1
      for dep in ''${line#*:}; do
        if [ ! -f "$moddir/$dep" ]; then
          ok=
          fail "MISSING module '$dep', a dependency of '$mod' per modules.dep, is not in the initrd, so '$mod' cannot load. '$mod' is needed because: $why."
        fi
      done
      if [ -n "$ok" ]; then echo "  ok  $mod (''${present[$n]}, $(wc -w <<<"''${line#*:}") deps$note)"; fi
    done

    # -- Nothing forbidden may be present, whatever dragged it in. Vetoing a
    # name in the module list does not stop the modules.dep closure of some
    # other listed module from copying it back.
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      resolve "$f"; n=$r
      fnote=''${via:+, alias of ''$r via ''$via}
      if [ -n "''${builtin[$n]:-}" ]; then
        echo "  warn  forbidden module '$f'$fnote is built into this kernel; the initrd cannot exclude it" >&2
        continue
      fi
      if [ -z "''${present[$n]:-}" ]; then
        echo "  ok  $f absent (forbidden$fnote)"; continue
      fi
      path=''${present[$n]}
      # Who lists it as a dependency, and which of those were required.
      pullers=() required=()
      for k in "''${!depline[@]}"; do
        l=''${depline[$k]}
        case " ''${l#*:} " in
          *" $path "*)
            pullers+=("$k")
            if [ -n "''${reasons[$k]:-}" ]; then required+=("''${display[$k]} [''${reasons[$k]}]"); fi ;;
        esac
      done
      msg="FORBIDDEN module '$f' ($path$fnote) is in the initrd (local.initrdGuard.forbiddenModules)."
      [ -n "''${reasons[$n]:-}" ] && msg+=" It is required directly: ''${reasons[$n]}."
      if [ ''${#required[@]} -gt 0 ]; then
        joined=$(printf '%s; ' "''${required[@]}"); msg+=" Pulled in via modules.dep by required module(s): ''${joined%; }."
      elif [ ''${#pullers[@]} -gt 0 ]; then
        msg+=" Depended on by: ''${pullers[*]}, none of which is itself required."
      elif [ -z "''${reasons[$n]:-}" ]; then
        msg+=" Nothing in modules.dep depends on it, so it was added by name (e.g. boot.initrd.includeDefaultModules or another module's availableKernelModules)."
      fi
      fail "$msg"
    done < "$forbidden"

    if [ "$failures" -gt 0 ]; then
      # Repeat the failures last: nix shows only the tail of a failed
      # build's log, and with dozens of "ok" lines the first report of a
      # missing module scrolls out of it (seen with the veto-form list).
      echo "initrd-guard: ---- summary ----" >&2
      for m in "''${failmsgs[@]}"; do echo "initrd-guard: $m" >&2; done
      echo "initrd-guard: $failures problem(s) in the built initrd ($initrd)." >&2
      echo "initrd-guard: a MISSING module means this machine would fail to boot it; a FORBIDDEN one" >&2
      echo "initrd-guard: means stage 1 can again hang on the device class it was excluded for." >&2
      echo "initrd-guard: The module lists are in system/configuration.nix (boot.initrd.*KernelModules)." >&2
      exit 1
    fi
    echo "initrd-guard: all ''${#order[@]} required modules and their dependencies are present, no forbidden ones"
  '';
in
{
  options.local.initrdGuard.forbiddenModules = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    example = [ "usb_storage" "uas" ];
    description = ''
      Kernel modules that must NOT end up in the built initrd; the build
      fails if one does. Removing a name from
      boot.initrd.availableKernelModules is not enough on its own, because
      the initrd also receives the modules.dep closure of every module
      that IS listed, so adding some unrelated driver that depends on a
      vetoed one silently copies it back. Exists for usb_storage/uas: a
      dying USB disk probed in stage 1 stalled boot for nine minutes
      (2026-10-28). Names match with - and _ interchangeable.
    '';
  };

  config.system.checks = [
    (pkgs.runCommand "initrd-guard" {
      nativeBuildInputs = with pkgs; [ coreutils gnugrep gawk cpio zstd xz gzip findutils ];
      passthru = { inherit check requirements forbidden; };
    } ''
      ${check} ${initrd}/initrd ${requirements} ${kernel.configfile} \
        ${kernel.modules}/lib/modules/${kernel.modDirVersion} "$TMPDIR/initrd-guard" ${forbidden} \
        > report 2>&1 || status=$?
      chmod -R u+w "$TMPDIR/initrd-guard" 2>/dev/null || true
      cat report
      [ "''${status:-0}" -eq 0 ] || exit 1
      cp report "$out"
    '')
  ];
}
