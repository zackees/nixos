#!/usr/bin/env bash
# ── Boots a built system in a throwaway VM before the real machine has to ──
#
#     scripts/verify-boot.sh                  boot ./result (else the current
#                                             system profile) up to multi-user
#     scripts/verify-boot.sh /nix/store/...-nixos-system-...   a given toplevel
#     scripts/verify-boot.sh --stage1-only    stop once stage 1 switches root
#     scripts/verify-boot.sh --timeout 300    hard limit in seconds (default 240)
#     scripts/verify-boot.sh --disk /dev/X    disk to boot (default: the disk
#                                             holding the toplevel's / and /boot)
#     scripts/verify-boot.sh --skip-fsck      add fsck.mode=skip (~45 s faster;
#                                             fsck of a live disk proves little)
#     scripts/verify-boot.sh --keep           keep the work dir (overlay + log)
#
# Exit status: 0 PASS, 1 FAIL (emergency shell, panic, timeout), 2 could not
# run the test at all, 3 UNSAFE (qemu held the real disk writable; aborted).
#
# Why: `nixos-rebuild build` and `switch` both succeed with an initrd that
# cannot mount the root filesystem, because the RUNNING kernel already has
# every driver loaded. Only the next boot fails, and it writes no journal.
# That happened for two weeks of generations (2026-10-30..11-15). This runs
# the toplevel's own kernel, initrd and kernel-params (+ init=, as systemd-boot
# would) under QEMU/KVM against the real root disk, so it fails the same way
# a reboot would -- before anyone reboots.
#
# Safety: the guest can never write the real disk, by construction rather
# than by flag alone.
#   - A root shell opens the disk O_RDONLY as fd 3, then drops to the calling
#     user (setpriv) and execs qemu. qemu runs unprivileged: it cannot open
#     the device itself (root:disk 0660), and the only handle it has is
#     read-only. It reaches it through `-add-fd` + /dev/fdset, which hands out
#     only fds whose access mode matches the request, so even a qemu bug
#     asking for O_RDWR gets EACCES, not a writable fd.
#   - The base node is read-only=on (and locking=off, so not even an advisory
#     OFD lock touches the device). All guest writes -- the ext4 journal
#     replay of the live, mounted root, fsck, stage-2 activation, /boot's
#     random-seed -- land in a qcow2 overlay in a temp dir, deleted afterwards.
#   - While the guest runs the script checks /proc/<qemu>/fdinfo: every fd on
#     the disk must have access mode O_RDONLY and qemu must run as the calling
#     user. Anything else kills the VM and exits 3.
#   - Direct kernel boot (no OVMF), so no EFI variables either; -nic none.
# The whole disk is used, not just the root partition, because stage 2 mounts
# /boot (no nofail) and would otherwise drop to emergency mode on its own.
#
# The guest sees a snapshot of a disk that is mounted and being written, so
# its view is inconsistent: expect "EXT4-fs error ... block bitmap and bg
# descriptor inconsistent" lines in stage 2. They describe the guest's view
# only (the overlay absorbs whatever ext4 writes about them) and the default
# errors=continue carries on. Stage 1 runs a real fsck, which replays the
# live journal into the overlay; it has passed every time so far, but if a
# FAIL ever comes from systemd-fsck rather than the mount, rerun with
# --skip-fsck before believing it -- the script says so when that happens.
#
# Needs root to read the block device: one `sudo -A` (KDE password dialog,
# 120 s to answer); the 15-minute ticket then covers the run itself.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TIMEOUT=240
STAGE1_ONLY=0
DISK=""
KEEP=0
SKIP_FSCK=0
TOP=""
MEM=8G
CPUS=4

while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --stage1-only) STAGE1_ONLY=1; shift ;;
    --disk) DISK="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --skip-fsck) SKIP_FSCK=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    -*) echo "unknown argument: $1" >&2; exit 2 ;;
    *) TOP="$1"; shift ;;
  esac
done

die() { echo "verify-boot: $*" >&2; exit 2; }

if [ -z "$TOP" ]; then
  if [ -e ./result/init ]; then TOP=./result; else TOP=/nix/var/nix/profiles/system; fi
fi
TOP="$(readlink -f "$TOP")"
for f in kernel initrd init kernel-params etc/fstab; do
  [ -e "$TOP/$f" ] || die "$TOP has no $f; is it a NixOS system toplevel?"
done
echo "toplevel: $TOP"

# ── Which disk: every block device the toplevel's fstab needs, resolved on
# this host, must sit on one disk, or the guest would be missing some.
if [ -z "$DISK" ]; then
  disks=()
  while read -r dev mnt _type opts _; do
    case "$dev" in /dev/*) ;; *) continue ;; esac
    case ",$opts," in *,nofail,*|*,noauto,*) continue ;; esac
    real="$(readlink -f "$dev")"
    [ -b "$real" ] || die "$mnt is on $dev, which does not exist on this host"
    parent="$(lsblk -ndo PKNAME "$real")"
    [ -n "$parent" ] || parent="$(basename "$real")"
    disks+=("/dev/$parent")
  done < <(grep -v '^[[:space:]]*#' "$TOP/etc/fstab")
  [ "${#disks[@]}" -gt 0 ] || die "no block devices in $TOP/etc/fstab"
  DISK="${disks[0]}"
  for d in "${disks[@]}"; do
    [ "$d" = "$DISK" ] || die "fstab spans $DISK and $d; pass --disk (only one is attached)"
  done
fi
[ -b "$DISK" ] || die "$DISK is not a block device"
DISK="$(readlink -f "$DISK")"
[ -w "$DISK" ] && echo "verify-boot: WARNING: $(id -un) can write $DISK directly;" \
  "the read-only fd is then the only barrier" >&2
SIZE=$(( $(cat "/sys/class/block/$(basename "$DISK")/size") * 512 ))
echo "disk:     $DISK ($(( SIZE / 1024**3 )) GiB, attached read-only + overlay)"

# ── qemu from this repo's pinned nixpkgs, unless one is supplied.
if [ -z "${QEMU:-}" ]; then
  qdir="$(nix build --no-link --print-out-paths --inputs-from "$REPO" nixpkgs#qemu_kvm)" \
    || die "could not build qemu_kvm"
  QEMU="$qdir/bin/qemu-system-x86_64"
  QEMU_IMG="$qdir/bin/qemu-img"
else
  QEMU_IMG="${QEMU_IMG:-$(dirname "$QEMU")/qemu-img}"
fi
[ -w /dev/kvm ] || die "/dev/kvm is not usable by $(id -un)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/verify-boot.XXXXXX")"
LOG="$WORK/console.log"
PIDF="$WORK/qemu.pid"
QPID=""
cleanup() {
  if [ -n "$QPID" ] && kill -0 "$QPID" 2>/dev/null; then
    kill -TERM "$QPID" 2>/dev/null || true
    sleep 1; kill -KILL "$QPID" 2>/dev/null || true
  fi
  wait 2>/dev/null || true
  if [ "$KEEP" = 1 ]; then echo "work dir kept: $WORK"
  else rm -f "$WORK/overlay.qcow2"; echo "console log: $LOG"; fi
}
trap cleanup EXIT

"$QEMU_IMG" create -q -f qcow2 "$WORK/overlay.qcow2" "$SIZE"
: > "$LOG"

CMDLINE="init=$TOP/init $(cat "$TOP/kernel-params") console=ttyS0,115200 systemd.show_status=true"
[ "$SKIP_FSCK" = 1 ] && CMDLINE="$CMDLINE fsck.mode=skip"
echo "cmdline:  $CMDLINE"

QARGS=(
  -name verify-boot -machine q35,accel=kvm -cpu host -smp "$CPUS" -m "$MEM"
  -nodefaults -display none -vga none -monitor none -nic none -no-reboot
  -serial "file:$LOG" -pidfile "$PIDF"
  -kernel "$TOP/kernel" -initrd "$TOP/initrd" -append "$CMDLINE"
  -add-fd fd=3,set=1,opaque=real-disk-ro
  -blockdev "driver=host_device,node-name=real-file,filename=/dev/fdset/1,read-only=on,locking=off"
  -blockdev "driver=raw,node-name=real,file=real-file,read-only=on"
  -blockdev "driver=file,node-name=ovl-file,filename=$WORK/overlay.qcow2"
  -blockdev "driver=qcow2,node-name=ovl,file=ovl-file,backing=real"
  -device "nvme,serial=VERIFYBOOT,drive=ovl"
)

echo "authenticating (sudo -A) to open $DISK read-only..."
timeout 120 sudo -A true || die "sudo authentication failed or timed out"

# The guest reads the DISK, not the host's page cache, so anything not yet
# written back is invisible to it. A toplevel built a minute ago is mostly
# still in dirty pages, and the guest then fails "Find NixOS closure" on a
# perfectly good build. sync writes it out and commits the journal; the
# guest replays that journal into its overlay. The root shell below also
# drops the DEVICE's page cache (blockdev --flushbufs; clean pages only,
# the same thing drop_caches does): ext4 writes file data around that
# cache, so blocks cached by an earlier run would be served stale.
# (cache.direct=on would avoid it, but qemu's fdset then demands an fd
# already opened O_DIRECT, which a shell redirect cannot do.)
echo "syncing filesystems so the guest sees the new store paths..."
sync

T0=$(date +%s.%N)
# The root shell only opens the fd and drops privileges; qemu itself is the
# calling user. `timeout` is a backstop -- the loop below normally ends it.
timeout -k 10 $(( TIMEOUT + 30 )) sudo -A -- /bin/sh -c '
  disk=$1 uid=$2 gid=$3 setpriv=$4 blockdev=$5; shift 5
  [ -r "$disk" ] || exit 97
  "$blockdev" --flushbufs "$disk" || exit 97
  exec 3<"$disk"
  exec "$setpriv" --reuid="$uid" --regid="$gid" --clear-groups -- "$@"
' verify-boot "$DISK" "$(id -u)" "$(id -g)" "$(command -v setpriv)" "$(command -v blockdev)" "$QEMU" "${QARGS[@]}" &
SUDO_PID=$!

now() { awk -v a="$T0" -v b="$(date +%s.%N)" 'BEGIN{printf "%.1f", b-a}'; }

# Proves, from the kernel's side, that qemu cannot write the disk: it runs as
# the calling user, and every fd it holds on the device is O_RDONLY.
safety_check() {
  local uids dev_rdev fd flags acc nfd=0 me
  me="$(id -u)"
  uids="$(awk '/^Uid:/{print $2,$3,$4,$5}' "/proc/$QPID/status")" || return 0
  [ "$uids" = "$me $me $me $me" ] || { reason="qemu uids are '$uids', not $me"; return 1; }
  dev_rdev="$(stat -Lc '%t:%T' "$DISK")"
  for fd in /proc/"$QPID"/fd/*; do
    [ -b "$fd" ] || continue
    [ "$(stat -Lc '%t:%T' "$fd")" = "$dev_rdev" ] || continue
    flags="$(awk '/^flags:/{print $2}' "/proc/$QPID/fdinfo/${fd##*/}")"
    acc=$(( 8#$flags & 3 ))
    echo "safety:   qemu pid $QPID fd ${fd##*/} -> $(readlink "$fd") flags=0$flags" \
      "access=$([ "$acc" = 0 ] && echo O_RDONLY || echo "WRITABLE($acc)")"
    [ "$acc" = 0 ] || { reason="fd ${fd##*/} on $DISK is writable"; return 1; }
    nfd=$((nfd + 1))
  done
  [ "$nfd" -gt 0 ] || { reason="qemu holds no fd on $DISK; cannot prove read-only"; return 1; }
  echo "safety:   qemu runs as uid $me; $nfd fd(s) on $DISK, all O_RDONLY"
}

FAIL_RE='emergency mode|Cannot open access to console|Kernel panic|An error occurred in stage 1|Failed to mount .*(sysroot|Root)|Dependency failed for .*(Initrd Root|sysroot)'
S1_RE='Reached target .*Switch Root|Starting .*Switch Root|<<< NixOS Stage 2 >>>'
S2_RE='Reached target .*Multi-User System'

verdict="" reason="" t_s1="" t_s2="" safe_checked=0
while :; do
  if [ -z "$QPID" ] && [ -s "$PIDF" ]; then QPID="$(cat "$PIDF")"; fi

  if [ "$safe_checked" = 0 ] && [ -n "$QPID" ] && [ -d "/proc/$QPID" ]; then
    if ! safety_check; then verdict=UNSAFE; break; fi
    safe_checked=1
  fi

  if grep -Eq "$FAIL_RE" "$LOG"; then verdict=FAIL; reason="emergency/panic on console"; break; fi
  if [ -z "$t_s1" ] && grep -Eq "$S1_RE" "$LOG"; then
    t_s1="$(now)"; echo "stage 1:  switched root at +${t_s1}s"
    if [ "$STAGE1_ONLY" = 1 ] && [ "$safe_checked" = 1 ]; then verdict=PASS; break; fi
  fi
  if [ -z "$t_s2" ] && grep -Eq "$S2_RE" "$LOG"; then
    t_s2="$(now)"; echo "stage 2:  multi-user.target at +${t_s2}s"
    if [ "$safe_checked" = 1 ]; then verdict=PASS; break; fi
  fi
  if ! kill -0 "$SUDO_PID" 2>/dev/null; then
    rc=0; wait "$SUDO_PID" || rc=$?
    verdict=FAIL; reason="qemu exited (status $rc) before a verdict"
    [ "$rc" = 97 ] && { verdict=ERROR; reason="root could not open or flush $DISK"; }
    break
  fi
  if awk -v t="$(now)" -v m="$TIMEOUT" 'BEGIN{exit !(t>=m)}'; then
    verdict=FAIL; reason="timeout after ${TIMEOUT}s"; break
  fi
  sleep 0.25
done
ELAPSED="$(now)"

if [ "$verdict" != UNSAFE ] && [ -n "$QPID" ] && [ -d "/proc/$QPID" ]; then
  echo "safety:   re-checking at the end of the run"
  safety_check || verdict=UNSAFE
fi
if [ -n "$QPID" ] && kill -0 "$QPID" 2>/dev/null; then kill -TERM "$QPID"; fi
wait "$SUDO_PID" 2>/dev/null || true

plain() { sed 's/\x1b\[[0-9;:]*[a-zA-Z]//g' "$LOG" | tr '\r' '\n' | grep -av 'A start job is running'; }
echo "---- deciding console lines ----"
plain | grep -Ea "$FAIL_RE|$S1_RE|$S2_RE|FAILED|DEPEND|Welcome to" | tail -n 25 || true
echo "--------------------------------"
if [ "$verdict" = FAIL ] && plain | grep -Eaq 'Failed to start .*File System Check'; then
  echo "NOTE: fsck failed in the guest. On a snapshot of a live disk that can be"
  echo "      an artefact, not a boot problem; rerun with --skip-fsck to tell."
fi
case "$verdict" in
  PASS)   echo "PASS: $( [ "$STAGE1_ONLY" = 1 ] && echo "stage 1 switched root" || echo "reached multi-user.target") in ${ELAPSED}s"; exit 0 ;;
  FAIL)   echo "FAIL: $reason (after ${ELAPSED}s; stage1=${t_s1:-never} multi-user=${t_s2:-never})"; plain | tail -n 15; exit 1 ;;
  UNSAFE) echo "UNSAFE: $reason -- VM killed"; exit 3 ;;
  *)      echo "ERROR: $reason"; exit 2 ;;
esac
